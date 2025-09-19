#!/bin/bash

# SocketCAN Tester Present Scanner
# Cycles through CAN IDs 0x000-0x7FF sending tester present signals
# and checking for responses on CAN ID + 0x08

CAN_INTERFACE="can0"
TIMEOUT=0.1  # Timeout in seconds for response
TESTER_PRESENT_DATA="02 10 01 00 00 00 00 00"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if can-utils are installed
check_dependencies() {
    if ! command -v cansend &> /dev/null || ! command -v candump &> /dev/null; then
        echo -e "${RED}Error: can-utils not found. Please install can-utils package.${NC}"
        echo "Ubuntu/Debian: sudo apt-get install can-utils"
        echo "RHEL/CentOS: sudo yum install can-utils"
        exit 1
    fi
}

# Function to check if CAN interface exists and is up
check_can_interface() {
    if ! ip link show $CAN_INTERFACE &> /dev/null; then
        echo -e "${RED}Error: CAN interface $CAN_INTERFACE not found.${NC}"
        echo "Available interfaces:"
        ip link show | grep can
        exit 1
    fi
    
    if ! ip link show $CAN_INTERFACE | grep -q "UP"; then
        echo -e "${YELLOW}Warning: CAN interface $CAN_INTERFACE is not UP.${NC}"
        echo "You may need to bring it up with:"
        echo "sudo ip link set $CAN_INTERFACE up type can bitrate 500000"
        read -p "Continue anyway? (y/n): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
}

# Function to send tester present and check for response
test_can_id() {
    local request_id=$1
    local response_id=$2
    
    # Start candump in background to capture response
    timeout $TIMEOUT candump $CAN_INTERFACE,${response_id}:7FF -n 1 2>/dev/null &
    local candump_pid=$!
    
    # Small delay to ensure candump is ready
    sleep 0.01
    
    # Send tester present message
    cansend $CAN_INTERFACE ${request_id}#${TESTER_PRESENT_DATA// /} 2>/dev/null
    
    # Wait for candump to finish or timeout
    local response=""
    if wait $candump_pid 2>/dev/null; then
        response=$(timeout $TIMEOUT candump $CAN_INTERFACE,${response_id}:7FF -n 1 2>/dev/null)
    fi
    
    # Check if we got a response
    if [ ! -z "$response" ]; then
        echo -e "${GREEN}[FOUND]${NC} Request: $request_id -> Response: $response_id"
        echo "        Response: $response"
        echo "$request_id,$response_id,$response" >> can_scan_results.txt
        return 0
    else
        echo -e "${RED}[NO RESPONSE]${NC} Request: $request_id -> Expected Response: $response_id"
        return 1
    fi
}

# Main scanning function
scan_can_ids() {
    local found_count=0
    local total_count=0
    
    echo -e "${YELLOW}Starting CAN ID scan from 0x000 to 0x7FF...${NC}"
    echo "Interface: $CAN_INTERFACE"
    echo "Tester Present: $TESTER_PRESENT_DATA"
    echo "Timeout: ${TIMEOUT}s"
    echo "Results will be saved to: can_scan_results.txt"
    echo "----------------------------------------"
    
    # Clear/create results file
    echo "Request_ID,Response_ID,Response_Data" > can_scan_results.txt
    
    # Loop through all CAN IDs from 0x000 to 0x7FF
    for ((i=0; i<=2047; i++)); do
        local request_id=$(printf "%03X" $i)
        local response_id=$(printf "%03X" $((i + 8)))
        
        # Skip if response ID would exceed 0x7FF
        if [ $((i + 8)) -gt 2047 ]; then
            continue
        fi
        
        total_count=$((total_count + 1))
        
        if test_can_id $request_id $response_id; then
            found_count=$((found_count + 1))
        fi
        
        # Progress indicator every 100 IDs
        if [ $((i % 100)) -eq 0 ]; then
            echo -e "${YELLOW}Progress: $i/2047 ($(($i * 100 / 2047))%)${NC}"
        fi
        
        # Small delay to prevent overwhelming the bus
        sleep 0.01
    done
    
    echo "----------------------------------------"
    echo -e "${GREEN}Scan completed!${NC}"
    echo "Total IDs tested: $total_count"
    echo "Responses found: $found_count"
    echo "Results saved to: can_scan_results.txt"
}

# Function to display usage
show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  -i INTERFACE    CAN interface (default: can0)"
    echo "  -t TIMEOUT      Response timeout in seconds (default: 0.1)"
    echo "  -h              Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 -i can1 -t 0.2"
}

# Parse command line arguments
while getopts "i:t:h" opt; do
    case $opt in
        i)
            CAN_INTERFACE="$OPTARG"
            ;;
        t)
            TIMEOUT="$OPTARG"
            ;;
        h)
            show_usage
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            show_usage
            exit 1
            ;;
    esac
done

# Main execution
echo "SocketCAN Tester Present Scanner"
echo "==============================="

# Check dependencies and interface
check_dependencies
check_can_interface

# Confirm before starting
echo ""
echo "Ready to scan CAN IDs 0x000-0x7FF on interface $CAN_INTERFACE"
read -p "Press Enter to start scanning or Ctrl+C to cancel..."

# Start the scan
scan_can_ids
