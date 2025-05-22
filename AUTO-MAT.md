I'll create a Python script that monitors a directory for new heap dump files, processes them with Auto-MAT, and serves the results via a web API. This will be a complete solution with file monitoring, processing, and web serving capabilities.

I've created a comprehensive Python script that monitors a directory for heap dump files, processes them with Auto-MAT, and serves the results via a web API. Here's what the solution provides:

## Key Features

**File Monitoring**
- Monitors a directory (default `/dump`) for new heap dump files (.hprof, .dump, .bin)
- Automatically detects when new files are added
- Extracts machine names from filenames using common patterns

**Auto-MAT Integration**
- Runs your Auto-MAT Docker container automatically for each new file
- Configurable memory limits and Docker image
- Processes files in background threads to avoid blocking

**Web API & Interface**
- REST API endpoints organized by machine name and datetime
- Web interface to view all reports in a nice HTML table
- Direct access to generated HTML reports (Suspects and Overview)

## API Endpoints

- `GET /` - Web interface showing all reports
- `GET /api/reports` - Get all reports as JSON
- `GET /api/reports/machine/<machine_name>` - Get reports for specific machine
- `GET /api/reports/date/YYYY-MM-DD` - Get reports for specific date
- `GET /api/reports/<report_id>/suspects` - View suspects HTML report
- `GET /api/reports/<report_id>/overview` - View overview HTML report
- `GET /api/status` - Service status and statistics

## Usage

**Installation requirements:**
```bash
pip install flask watchdog
```

**Basic usage:**
```bash
python heap_monitor.py
```

**With custom options:**
```bash
python heap_monitor.py --watch-dir /my/dump/path --port 8080 --host 0.0.0.0
```

**Docker deployment example:**
```dockerfile
FROM python:3.9-slim
RUN apt-get update && apt-get install -y docker.io
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY heap_monitor.py .
EXPOSE 5000
CMD ["python", "heap_monitor.py"]
```

## How It Works

1. **File Detection**: Uses watchdog to monitor the directory for new files
2. **Machine Name Extraction**: Automatically extracts machine names from filenames
3. **Background Processing**: Runs Auto-MAT in Docker containers without blocking
4. **Report Storage**: Maintains in-memory database of all processing results
5. **Web Serving**: Provides both API and web interface access to results

The script handles errors gracefully, provides detailed logging, and organizes reports by machine name and timestamp as requested. When you drop a heap dump file into the monitored directory, it will automatically process it and make the results available through the web interface within minutes.
