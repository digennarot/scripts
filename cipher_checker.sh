#!/bin/bash

# Tomcat Top 3 Cipher Suite Checker with Java Support Verification
# Fetches cipher suites from Mozilla SSL Configuration Generator
# Also checks Java cipher support using jshell
# Dynamically uses latest guideline version from Mozilla

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Mozilla guidelines URLs
MOZILLA_LATEST_URL="https://raw.githubusercontent.com/mozilla/ssl-config-generator/refs/heads/master/src/static/guidelines/latest.json"
MOZILLA_GUIDELINES_BASE_URL="https://raw.githubusercontent.com/mozilla/ssl-config-generator/refs/heads/master/src/static/guidelines"

# Function to print usage
usage() {
    echo "Usage: $0 <hostname> [port] [config_level]"
    echo "  hostname: Target server hostname or IP"
    echo "  port: SSL port (default: 443)"
    echo "  config_level: modern|intermediate|old (default: intermediate)"
    echo ""
    echo "Example: $0 example.com 8443 intermediate"
    echo ""
    echo "This script will:"
    echo "  1. Check Java cipher suite support using jshell"
    echo "  2. Test actual SSL connection to your server"
    echo "  3. Compare results with Mozilla recommendations"
    exit 1
}

# Function to check if required tools are available
check_dependencies() {
    local missing_tools=()
    
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        missing_tools+=("curl or wget")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi
    
    if ! command -v openssl &> /dev/null; then
        missing_tools+=("openssl")
    fi
    
    if ! command -v jshell &> /dev/null; then
        echo -e "${YELLOW}Warning: jshell not found. Java cipher support check will be skipped.${NC}"
        echo -e "${YELLOW}Install Java 9+ with JDK to enable Java cipher verification.${NC}"
        USE_JSHELL=false
    else
        USE_JSHELL=true
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo -e "${RED}Error: Missing required tools: ${missing_tools[*]}${NC}"
        echo "Please install the missing tools:"
        echo "  Ubuntu/Debian: sudo apt-get install curl jq openssl default-jdk"
        echo "  CentOS/RHEL: sudo yum install curl jq openssl java-11-openjdk-devel"
        echo "  macOS: brew install curl jq openssl openjdk"
        exit 1
    fi
    
    if ! command -v nmap &> /dev/null; then
        echo -e "${YELLOW}Warning: nmap not found. Will use openssl only${NC}"
        USE_NMAP=false
    else
        USE_NMAP=true
    fi
}

# Function to get latest guideline version
get_latest_version() {
    local temp_file=$(mktemp)
    
    echo -e "${BLUE}Fetching latest guideline version...${NC}"
    
    if command -v curl &> /dev/null; then
        curl -s "$MOZILLA_LATEST_URL" -o "$temp_file"
    else
        wget -q "$MOZILLA_LATEST_URL" -O "$temp_file"
    fi
    
    if [ $? -ne 0 ] || [ ! -s "$temp_file" ]; then
        echo -e "${YELLOW}Warning: Failed to fetch latest version, using fallback 5.7${NC}"
        rm -f "$temp_file"
        echo "5.7"
        return
    fi
    
    # Extract version from latest.json
    local version=$(jq -r '.version' "$temp_file" 2>/dev/null)
    
    if [ -z "$version" ] || [ "$version" = "null" ]; then
        echo -e "${YELLOW}Warning: Could not parse version, using fallback 5.7${NC}"
        version="5.7"
    fi
    
    rm -f "$temp_file"
    echo "$version"
}

# Function to download Mozilla guidelines
fetch_mozilla_guidelines() {
    local version=$1
    local temp_file=$(mktemp)
    local guidelines_url="${MOZILLA_GUIDELINES_BASE_URL}/${version}.json"
    
    echo -e "${BLUE}Fetching Mozilla SSL guidelines v${version}...${NC}"
    
    if command -v curl &> /dev/null; then
        curl -s "$guidelines_url" -o "$temp_file"
    else
        wget -q "$guidelines_url" -O "$temp_file"
    fi
    
    if [ $? -ne 0 ] || [ ! -s "$temp_file" ]; then
        echo -e "${RED}Failed to fetch Mozilla guidelines v${version}${NC}"
        
        # Try fallback version if not already using it
        if [ "$version" != "5.7" ]; then
            echo -e "${YELLOW}Trying fallback version 5.7...${NC}"
            rm -f "$temp_file"
            temp_file=$(mktemp)
            guidelines_url="${MOZILLA_GUIDELINES_BASE_URL}/5.7.json"
            
            if command -v curl &> /dev/null; then
                curl -s "$guidelines_url" -o "$temp_file"
            else
                wget -q "$guidelines_url" -O "$temp_file"
            fi
            
            if [ $? -ne 0 ] || [ ! -s "$temp_file" ]; then
                echo -e "${RED}Failed to fetch fallback guidelines${NC}"
                rm -f "$temp_file"
                exit 1
            fi
        else
            rm -f "$temp_file"
            exit 1
        fi
    fi
    
    echo "$temp_file"
}

# Function to extract cipher suites from Mozilla JSON
get_cipher_suites() {
    local guidelines_file=$1
    local config_level=$2
    
    # Extract cipher suites for the specified configuration level
    local ciphers=$(jq -r ".configurations.${config_level}.ciphersuites[]" "$guidelines_file" 2>/dev/null)
    
    if [ -z "$ciphers" ]; then
        echo -e "${RED}Failed to extract cipher suites for ${config_level} configuration${NC}"
        return 1
    fi
    
    echo "$ciphers"
}

# Function to get TLS versions
get_tls_versions() {
    local guidelines_file=$1
    local config_level=$2
    
    local tls_versions=$(jq -r ".configurations.${config_level}.tls_versions[]" "$guidelines_file" 2>/dev/null)
    echo "$tls_versions"
}

# Function to check Java cipher support using jshell
check_java_cipher_support() {
    local cipher_suites=$1
    
    echo -e "${CYAN}Checking Java cipher suite support...${NC}"
    
    # Get Java version info
    local java_version=$(java -version 2>&1 | head -1)
    echo "Java Version: $java_version"
    echo ""
    
    # Create temporary jshell script
    local jshell_script=$(mktemp)
    
    cat > "$jshell_script" << 'EOF'
import javax.net.ssl.*;
import java.security.Security;
import java.util.*;

// Get default SSL context and supported cipher suites
SSLContext context = SSLContext.getDefault();
SSLEngine engine = context.createSSLEngine();
String[] supportedCiphers = engine.getSupportedCipherSuites();
String[] enabledCiphers = engine.getEnabledCipherSuites();

// Convert to sets for easier checking
Set<String> supportedSet = new HashSet<>(Arrays.asList(supportedCiphers));
Set<String> enabledSet = new HashSet<>(Arrays.asList(enabledCiphers));

System.out.println("=== Java SSL Engine Information ===");
System.out.println("Total supported cipher suites: " + supportedCiphers.length);
System.out.println("Total enabled cipher suites: " + enabledCiphers.length);
System.out.println();

// Function to check cipher support
void checkCipher(String cipher) {
    boolean supported = supportedSet.contains(cipher);
    boolean enabled = enabledSet.contains(cipher);
    
    String status = "UNSUPPORTED";
    if (supported && enabled) {
        status = "SUPPORTED & ENABLED";
    } else if (supported) {
        status = "SUPPORTED (disabled)";
    }
    
    System.out.println("Java: " + cipher + " - " + status);
}

// Check specific ciphers (will be replaced by script)
CIPHER_CHECKS

System.out.println();
System.out.println("=== Security Providers ===");
for (int i = 0; i < Security.getProviders().length; i++) {
    System.out.println((i+1) + ". " + Security.getProviders()[i].getName() + 
                      " v" + Security.getProviders()[i].getVersion());
}

/exit
EOF

    # Build cipher check commands
    local cipher_checks=""
    while IFS= read -r cipher; do
        if [ -n "$cipher" ]; then
            cipher_checks="${cipher_checks}checkCipher(\"${cipher}\");\n"
        fi
    done <<< "$cipher_suites"
    
    # Replace placeholder with actual cipher checks
    sed -i "s/CIPHER_CHECKS/${cipher_checks}/" "$jshell_script"
    
    # Run jshell script
    local java_output=$(timeout 30 jshell --no-startup "$jshell_script" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        echo "$java_output"
    else
        echo -e "${RED}Failed to run Java cipher check${NC}"
    fi
    
    echo ""
    rm -f "$jshell_script"
}

# Function to test individual cipher
test_cipher() {
    local hostname=$1
    local port=$2
    local cipher=$3
    local tls_versions=$4
    
    echo -e "${BLUE}Testing cipher: ${cipher}${NC}"
    
    # Try different TLS versions
    local supported=false
    for tls_version in $tls_versions; do
        local tls_flag=""
        case $tls_version in
            "TLSv1.2") tls_flag="-tls1_2" ;;
            "TLSv1.3") tls_flag="-tls1_3" ;;
            *) continue ;;
        esac
        
        local result=$(echo "Q" | timeout 10 openssl s_client -connect "${hostname}:${port}" -cipher "${cipher}" -servername "${hostname}" ${tls_flag} 2>/dev/null)
        
        if echo "$result" | grep -q "Cipher is ${cipher}"; then
            echo -e "${GREEN}✓ Server: ${cipher} - SUPPORTED (${tls_version})${NC}"
            
            # Extract additional details
            local protocol=$(echo "$result" | grep "Protocol" | head -1 | awk '{print $3}')
            local key_exchange=$(echo "$result" | grep "Server public key" | awk '{print $5 " " $6}')
            local signature=$(echo "$result" | grep "Server Temp Key" | cut -d':' -f2- | xargs)
            
            echo -e "  Protocol: ${protocol:-Unknown}"
            echo -e "  Key Exchange: ${key_exchange:-Unknown}"
            [ -n "$signature" ] && echo -e "  Temp Key: ${signature}"
            echo ""
            supported=true
            break
        fi
    done
    
    if [ "$supported" = false ]; then
        echo -e "${RED}✗ Server: ${cipher} - NOT SUPPORTED${NC}"
        echo ""
        return 1
    fi
    
    return 0
}

# Function to check SSL/TLS configuration
check_ssl_config() {
    local hostname=$1
    local port=$2
    
    echo -e "${BLUE}Checking SSL/TLS configuration...${NC}"
    
    local result=$(echo "Q" | timeout 10 openssl s_client -connect "${hostname}:${port}" -servername "${hostname}" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ SSL/TLS connection successful${NC}"
        
        # Extract certificate info
        local subject=$(echo "$result" | grep "subject=" | head -1)
        local issuer=$(echo "$result" | grep "issuer=" | head -1)
        local protocol=$(echo "$result" | grep "Protocol" | head -1)
        
        echo "$subject"
        echo "$issuer"
        echo "$protocol"
        echo ""
    else
        echo -e "${RED}✗ Failed to establish SSL/TLS connection${NC}"
        echo ""
        return 1
    fi
}

# Function to display configuration info
show_config_info() {
    local guidelines_file=$1
    local config_level=$2
    local version=$3
    
    echo -e "${BLUE}Mozilla ${config_level} Configuration (v${version}):${NC}"
    
    local tls_versions=$(get_tls_versions "$guidelines_file" "$config_level")
    echo "TLS Versions: $(echo $tls_versions | tr '\n' ' ')"
    
    local total_ciphers=$(jq -r ".configurations.${config_level}.ciphersuites | length" "$guidelines_file" 2>/dev/null)
    echo "Total Cipher Suites: ${total_ciphers}"
    
    # Show guideline metadata if available
    local guideline_date=$(jq -r '.date // empty' "$guidelines_file" 2>/dev/null)
    if [ -n "$guideline_date" ]; then
        echo "Guideline Date: ${guideline_date}"
    fi
    
    echo ""
}

# Main function
main() {
    if [ $# -lt 1 ] || [ $# -gt 3 ]; then
        usage
    fi
    
    local hostname=$1
    local port=${2:-443}
    local config_level=${3:-intermediate}
    
    # Validate config level
    if [[ ! "$config_level" =~ ^(modern|intermediate|old)$ ]]; then
        echo -e "${RED}Invalid config level. Use: modern, intermediate, or old${NC}"
        exit 1
    fi
    
    echo "========================================"
    echo "Tomcat Cipher Suite Checker with Java Support"
    echo "========================================"
    echo "Target: ${hostname}:${port}"
    echo "Config Level: ${config_level}"
    echo "========================================"
    echo ""
    
    check_dependencies
    
    # Get latest guideline version
    local guideline_version=$(get_latest_version)
    echo "Using Mozilla SSL Config Guidelines v${guideline_version}"
    echo ""
    
    # Fetch Mozilla guidelines
    local guidelines_file=$(fetch_mozilla_guidelines "$guideline_version")
    
    # Show configuration info
    show_config_info "$guidelines_file" "$config_level" "$guideline_version"
    
    # Get cipher suites and TLS versions
    local cipher_suites=$(get_cipher_suites "$guidelines_file" "$config_level")
    local tls_versions=$(get_tls_versions "$guidelines_file" "$config_level")
    
    if [ -z "$cipher_suites" ]; then
        rm -f "$guidelines_file"
        exit 1
    fi
    
    # Convert to array and get top 3
    local top_ciphers=($(echo "$cipher_suites" | head -3))
    
    # Check Java cipher support first
    if [ "$USE_JSHELL" = true ]; then
        check_java_cipher_support "$(echo "${top_ciphers[@]}" | tr ' ' '\n')"
    fi
    
    # Check basic SSL connectivity
    if ! check_ssl_config "$hostname" "$port"; then
        echo -e "${RED}Cannot establish SSL connection. Please check hostname and port.${NC}"
        rm -f "$guidelines_file"
        exit 1
    fi
    
    echo -e "${YELLOW}Testing Top 3 ${config_level^} Cipher Suites on Server:${NC}"
    echo ""
    
    local supported_count=0
    
    for cipher in "${top_ciphers[@]}"; do
        if test_cipher "$hostname" "$port" "$cipher" "$tls_versions"; then
            ((supported_count++))
        fi
    done
    
    echo "========================================"
    echo -e "Server Summary: ${supported_count}/${#top_ciphers[@]} top cipher suites supported"
    
    if [ $supported_count -eq ${#top_ciphers[@]} ]; then
        echo -e "${GREEN}✓ Excellent! All top cipher suites are supported by server${NC}"
    elif [ $supported_count -gt 0 ]; then
        echo -e "${YELLOW}⚠ Good! Some top cipher suites are supported by server${NC}"
    else
        echo -e "${RED}✗ Warning! None of the top cipher suites are supported by server${NC}"
    fi
    
    echo "========================================"
    
    # Show all available cipher suites for reference
    echo ""
    echo -e "${BLUE}All ${config_level^} Cipher Suites from Mozilla:${NC}"
    echo "$cipher_suites" | nl -w2 -s'. '
    
    # Optional comprehensive scan with nmap
    if [ "$USE_NMAP" = true ]; then
        echo ""
        read -p "Run comprehensive cipher scan with nmap? (y/N): " -n 1 -r
        echo ""
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            echo -e "${BLUE}Running comprehensive cipher scan with nmap...${NC}"
            echo ""
            nmap --script ssl-enum-ciphers -p "${port}" "${hostname}" 2>/dev/null | \
            grep -E "(TLS|SSL|cipher|strength)" | \
            head -20
        fi
    fi
    
    # Troubleshooting tips
    echo ""
    echo -e "${CYAN}Troubleshooting Tips:${NC}"
    echo "• If Java supports a cipher but server doesn't: Check Tomcat SSL configuration"
    echo "• If server supports a cipher but Java doesn't: Consider Java version upgrade"
    echo "• For TLSv1.3: Requires Java 11+ and proper Tomcat configuration"
    echo "• For modern ciphers: May need Java 8u261+ or newer versions"
    
    # Cleanup
    rm -f "$guidelines_file"
    
    echo ""
    echo "Mozilla SSL Config Generator:"
    echo "https://ssl-config.mozilla.org/#server=tomcat&version=10.1&config=${config_level}&guideline=${guideline_version}"
}

# Run main function with all arguments
main "$@"
