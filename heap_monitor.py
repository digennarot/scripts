#!/usr/bin/env python3
"""
Heap Dump Monitor and Web Server
Monitors a directory for new heap dump files, processes them with Auto-MAT,
and serves the results via a REST API organized by machine name and datetime.
"""
import os
import sys
import time
import subprocess
import threading
import logging
import re
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional
from dataclasses import dataclass, asdict

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from flask import Flask, jsonify, send_file, request, render_template_string, url_for
import argparse

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('heap_monitor.log'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger(__name__)

@dataclass
class HeapDumpReport:
    """Data structure for heap dump analysis reports"""
    machine_name: str
    timestamp: datetime
    filename: str
    file_path: str
    status: str  # 'processing', 'completed', 'failed'
    suspects_report: Optional[str] = None
    overview_report: Optional[str] = None
    error_message: Optional[str] = None
    processing_time: Optional[float] = None


class HeapDumpProcessor:
    """Handles processing of heap dump files with Auto-MAT"""
    def __init__(self, docker_image: str = "docker.bintray.io/jfrog/auto-mat"):
        self.docker_image = docker_image

    def process_heap_dump(self, file_path: str, memory_limit: str = "11g") -> Dict:
        """Process a heap dump file using Auto-MAT Docker container"""
        try:
            start_time = time.time()
            file_dir = os.path.dirname(file_path)
            filename = os.path.basename(file_path)
            # Run Auto-MAT Docker container
            cmd = [
                "docker", "run", "--rm",
                "--mount", f"src={file_dir},target=/data,type=bind",
                self.docker_image,
                filename,
                memory_limit,
                "suspects,overview"
            ]
            logger.info(f"Running Auto-MAT for {filename}: {' '.join(cmd)}")
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=3600  # 1 hour timeout
            )
            processing_time = time.time() - start_time
            if result.returncode == 0:
                # Look for generated HTML reports
                base_name = os.path.splitext(filename)[0]
                suspects_path = os.path.join(file_dir, f"{base_name}_Leak_Suspects.html")
                overview_path = os.path.join(file_dir, f"{base_name}_System_Overview.html")
                return {
                    'status': 'completed',
                    'suspects_report': suspects_path if os.path.exists(suspects_path) else None,
                    'overview_report': overview_path if os.path.exists(overview_path) else None,
                    'processing_time': processing_time
                }
            else:
                logger.error(f"Auto-MAT failed for {filename}: {result.stderr}")
                return {
                    'status': 'failed',
                    'error_message': result.stderr,
                    'processing_time': processing_time
                }
        except subprocess.TimeoutExpired:
            logger.error(f"Processing timeout for {filename}")
            return {
                'status': 'failed',
                'error_message': 'Processing timeout (1 hour exceeded)',
                'processing_time': 3600
            }
        except Exception as e:
            logger.error(f"Error processing {filename}: {str(e)}")
            return {
                'status': 'failed',
                'error_message': str(e),
                'processing_time': time.time() - start_time if 'start_time' in locals() else 0
            }


class HeapDumpHandler(FileSystemEventHandler):
    """File system event handler for monitoring heap dump files"""
    def __init__(self, processor: HeapDumpProcessor, report_manager: 'ReportManager'):
        self.processor = processor
        self.report_manager = report_manager
        self.heap_dump_extensions = {'.hprof', '.dump', '.bin'}

    def on_created(self, event):
        if event.is_directory:
            return
        file_path = event.src_path
        if any(file_path.lower().endswith(ext) for ext in self.heap_dump_extensions):
            # Wait a bit to ensure file is completely written
            time.sleep(2)
            self._process_heap_dump(file_path)

    def _process_heap_dump(self, file_path: str):
        """Process a newly detected heap dump file"""
        try:
            filename = os.path.basename(file_path)
            machine_name = self._extract_machine_name(filename)
            timestamp = datetime.now()
            # Create initial report entry
            report = HeapDumpReport(
                machine_name=machine_name,
                timestamp=timestamp,
                filename=filename,
                file_path=file_path,
                status='processing'
            )
            self.report_manager.add_report(report)
            logger.info(f"Started processing heap dump: {filename}")
            # Process in background thread
            thread = threading.Thread(
                target=self._background_process,
                args=(report,)
            )
            thread.daemon = True
            thread.start()
        except Exception as e:
            logger.error(f"Error initiating processing for {file_path}: {str(e)}")

    def _background_process(self, report: HeapDumpReport):
        """Background processing of heap dump"""
        try:
            result = self.processor.process_heap_dump(report.file_path)
            # Update report with results
            report.status = result['status']
            report.suspects_report = result.get('suspects_report')
            report.overview_report = result.get('overview_report')
            report.error_message = result.get('error_message')
            report.processing_time = result.get('processing_time')
            self.report_manager.update_report(report)
            if result['status'] == 'completed':
                logger.info(f"Successfully processed {report.filename} in {result['processing_time']:.2f}s")
            else:
                logger.error(f"Failed to process {report.filename}: {result.get('error_message', 'Unknown error')}")
        except Exception as e:
            report.status = 'failed'
            report.error_message = str(e)
            self.report_manager.update_report(report)
            logger.error(f"Background processing error for {report.filename}: {str(e)}")

    def _extract_machine_name(self, filename: str) -> str:
        """Extract machine name from filename"""
        patterns = [
            r'^([^_]+)_.*',     # machine_timestamp
            r'.*_([^_]+)_.*',   # prefix_machine_suffix
            r'^([^.]+)\..*'     # fallback to filename without extension
        ]
        for pattern in patterns:
            match = re.match(pattern, filename)
            if match:
                return match.group(1)
        # Fallback
        return os.path.splitext(filename)[0]

class ReportManager:
    """Manages heap dump reports and provides access methods"""
    def __init__(self):
        self.reports: Dict[str, HeapDumpReport] = {}
        self.lock = threading.Lock()

    def add_report(self, report: HeapDumpReport):
        """Add a new report"""
        with self.lock:
            report_id = f"{report.machine_name}_{report.timestamp.strftime('%Y%m%d_%H%M%S')}"
            self.reports[report_id] = report

    def update_report(self, report: HeapDumpReport):
        """Update an existing report"""
        with self.lock:
            report_id = f"{report.machine_name}_{report.timestamp.strftime('%Y%m%d_%H%M%S')}"
            if report_id in self.reports:
                self.reports[report_id] = report

    def get_reports_by_machine(self, machine_name: str) -> List[HeapDumpReport]:
        """Get all reports for a specific machine"""
        with self.lock:
            return [report for report in self.reports.values() if report.machine_name == machine_name]

    def get_reports_by_date(self, date_str: str) -> List[HeapDumpReport]:
        """Get all reports for a specific date (YYYY-MM-DD)"""
        try:
            target_date = datetime.strptime(date_str, '%Y-%m-%d').date()
            with self.lock:
                return [report for report in self.reports.values() if report.timestamp.date() == target_date]
        except ValueError:
            return []

    def get_all_reports(self) -> List[HeapDumpReport]:
        """Get all reports"""
        with self.lock:
            return list(self.reports.values())

    def get_report_by_id(self, report_id: str) -> Optional[HeapDumpReport]:
        """Get a specific report by ID"""
        with self.lock:
            return self.reports.get(report_id)


def create_app(report_manager: ReportManager) -> Flask:
    """Create Flask application with API endpoints"""
    app = Flask(__name__, static_folder='static')

    # HTML template for report listing with linked CSS
    REPORT_LIST_TEMPLATE = """
    <!DOCTYPE html>
    <html>
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Heap Dump Reports</title>
        <link rel="stylesheet" href="{{ url_for('static', filename='css/style.css') }}">
    </head>
    <body>
        <h1>Heap Dump Analysis Reports</h1>
        <table>
            <tr>
                <th>Machine</th>
                <th>Timestamp</th>
                <th>Filename</th>
                <th>Status</th>
                <th>Processing Time</th>
                <th>Reports</th>
            </tr>
            {% for report in reports %}
            <tr>
                <td>{{ report.machine_name }}</td>
                <td>{{ report.timestamp.strftime('%Y-%m-%d %H:%M:%S') }}</td>
                <td>{{ report.filename }}</td>
                <td class="status-{{ report.status }}">{{ report.status }}</td>
                <td>{{ report.processing_time|default('N/A') }}s</td>
                <td class="reports-links">
                    {% if report.suspects_report %}
                        <a href="/api/reports/{{ report.machine_name }}_{{ report.timestamp.strftime('%Y%m%d_%H%M%S') }}/suspects" target="_blank">Suspects</a>
                    {% endif %}
                    {% if report.overview_report %}
                        <a href="/api/reports/{{ report.machine_name }}_{{ report.timestamp.strftime('%Y%m%d_%H%M%S') }}/overview" target="_blank">Overview</a>
                    {% endif %}
                    {% if report.error_message %}
                        <span class="error-message">{{ report.error_message }}</span>
                    {% endif %}
                </td>
            </tr>
            {% endfor %}
        </table>
    </body>
    </html>
    """

    @app.route('/')
    def index():
        """Main page showing all reports"""
        reports = sorted(report_manager.get_all_reports(), key=lambda x: x.timestamp, reverse=True)
        return render_template_string(REPORT_LIST_TEMPLATE, reports=reports)

    @app.route('/api/reports')
    def get_all_reports():
        """API endpoint to get all reports"""
        reports = report_manager.get_all_reports()
        return jsonify([asdict(report) for report in reports])

    @app.route('/api/reports/machine/<machine_name>')
    def get_reports_by_machine(machine_name: str):
        """API endpoint to get reports by machine name"""
        reports = report_manager.get_reports_by_machine(machine_name)
        return jsonify([asdict(report) for report in reports])

    @app.route('/api/reports/date/<date_str>')
    def get_reports_by_date(date_str: str):
        """API endpoint to get reports by date (YYYY-MM-DD)"""
        reports = report_manager.get_reports_by_date(date_str)
        return jsonify([asdict(report) for report in reports])

    @app.route('/api/reports/<report_id>/suspects')
    def get_suspects_report(report_id: str):
        """Serve suspects HTML report"""
        report = report_manager.get_report_by_id(report_id)
        if not report or not report.suspects_report or not os.path.exists(report.suspects_report):
            return jsonify({'error': 'Suspects report not found'}), 404
        return send_file(report.suspects_report)

    @app.route('/api/reports/<report_id>/overview')
    def get_overview_report(report_id: str):
        """Serve overview HTML report"""
        report = report_manager.get_report_by_id(report_id)
        if not report or not report.overview_report or not os.path.exists(report.overview_report):
            return jsonify({'error': 'Overview report not found'}), 404
        return send_file(report.overview_report)

    @app.route('/api/status')
    def get_status():
        """Get service status"""
        total_reports = len(report_manager.get_all_reports())
        processing = len([r for r in report_manager.get_all_reports() if r.status == 'processing'])
        completed = len([r for r in report_manager.get_all_reports() if r.status == 'completed'])
        failed = len([r for r in report_manager.get_all_reports() if r.status == 'failed'])
        return jsonify({
            'status': 'running',
            'total_reports': total_reports,
            'processing': processing,
            'completed': completed,
            'failed': failed
        })

    return app


def main():
    """Main application entry point"""
    parser = argparse.ArgumentParser(description='Heap Dump Monitor and Web Server')
    parser.add_argument('--watch-dir', default='/dump', help='Directory to monitor for heap dumps')
    parser.add_argument('--port', type=int, default=5000, help='Web server port')
    parser.add_argument('--host', default='0.0.0.0', help='Web server host')
    parser.add_argument('--docker-image', default='docker.bintray.io/jfrog/auto-mat', help='Auto-MAT Docker image')
    args = parser.parse_args()

    # Create watch directory if it doesn't exist
    watch_dir = Path(args.watch_dir)
    watch_dir.mkdir(parents=True, exist_ok=True)
    logger.info(f"Starting Heap Dump Monitor")
    logger.info(f"Watch directory: {watch_dir}")
    logger.info(f"Web server: http://{args.host}:{args.port}")

    # Initialize components
    processor = HeapDumpProcessor(args.docker_image)
    report_manager = ReportManager()

    # Set up file system monitoring
    event_handler = HeapDumpHandler(processor, report_manager)
    observer = Observer()
    observer.schedule(event_handler, str(watch_dir), recursive=False)
    observer.start()
    logger.info(f"File monitoring started for directory: {watch_dir}")

    # Create and start web application
    app = create_app(report_manager)
    try:
        app.run(host=args.host, port=args.port, debug=False, threaded=True)
    except KeyboardInterrupt:
        logger.info("Shutting down...")
    finally:
        observer.stop()
        observer.join()
        logger.info("Shutdown complete")

if __name__ == '__main__':
    main()
