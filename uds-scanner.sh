#!/bin/bash

# Controller UDS Scanner (Fixed Version)
# Scans for active diagnostic services using SocketCAN
# CAN Interface: can0
# Padding: 0x55

set -e

# Configuration
CAN_INTERFACE="can0"
TX_ID="7E0"
RX_ID="7E8"
PADDING_BYTE="55"
TIMEOUT=2

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if CAN interface is available
check_can_interface() {
    if ! ip link show "$CAN_INTERFACE" >/dev/null 2>&1; then
        print_error "CAN interface $CAN_INTERFACE not found!"
        print_error "Please ensure the interface is configured:"
        print_error "  sudo modprobe can"
        print_error "  sudo modprobe can_raw"
        print_error "  sudo ip link set $CAN_INTERFACE type can bitrate 500000"
        print_error "  sudo ip link set up $CAN_INTERFACE"
        exit 1
    fi
    
    if ! ip link show "$CAN_INTERFACE" | grep -q "UP"; then
        print_error "CAN interface $CAN_INTERFACE is not UP!"
        print_error "Please bring it up with: sudo ip link set up $CAN_INTERFACE"
        exit 1
    fi
}

# Function to calculate correct PCI length byte
calculate_length() {
    local service_id="$1"
    local sub_function="$2"
    local data_params="$3"
    
    local length=1  # Always start with 1 for the service ID
    
    if [ -n "$sub_function" ]; then
        length=$((length + 1))  # Add 1 for sub-function
    fi
    
    if [ -n "$data_params" ]; then
        # Count data parameter bytes (each pair of hex chars = 1 byte)
        local param_bytes=$((${#data_params} / 2))
        length=$((length + param_bytes))
    fi
    
    printf "%02X" "$length"
}

# Function to send UDS message and wait for response
send_uds_message() {
    local service_id="$1"
    local sub_function="$2"
    local data_params="$3"
    local description="$4"
    
    # Calculate correct length byte
    local length_byte=$(calculate_length "$service_id" "$sub_function" "$data_params")
    
    # Construct the UDS message (PCI + SID + sub-function + data)
    local message="${length_byte}${service_id}"
    
    if [ -n "$sub_function" ]; then
        message="${message}${sub_function}"
    fi
    
    if [ -n "$data_params" ]; then
        message="${message}${data_params}"
    fi
    
    # Pad message to 8 bytes with padding byte
    while [ ${#message} -lt 16 ]; do
        message="${message}${PADDING_BYTE}"
    done
    
    print_status "Testing $description"
    print_status "Sending: $TX_ID#$message"
    
    # Send the message using cansend
    if ! cansend "$CAN_INTERFACE" "$TX_ID#$message" 2>/dev/null; then
        print_error "Failed to send CAN message"
        return 1
    fi
    
    # Listen for response with timeout
    local response
    response=$(timeout "$TIMEOUT" candump "$CAN_INTERFACE,${RX_ID}:7FF" -n 1 2>/dev/null | head -n 1 || true)
    
    if [ -n "$response" ]; then
        print_success "Response received: $response"
        
        # Parse the response
        local data=$(echo "$response" | grep -o '#.*' | cut -c2-)
        local pci=$(echo "$data" | cut -c1-2)
        local response_sid=$(echo "$data" | cut -c3-4)
        
        # Check for positive response (SID + 0x40) or negative response (0x7F)
        if [ "$response_sid" = "7F" ]; then
            local requested_sid=$(echo "$data" | cut -c5-6)
            local nrc=$(echo "$data" | cut -c7-8)
            print_warning "Negative response - SID: $requested_sid, NRC: 0x$nrc"
            case "$nrc" in
                "10") print_warning "  -> General reject" ;;
                "11") print_warning "  -> Service not supported" ;;
                "12") print_warning "  -> Sub-function not supported" ;;
                "13") print_warning "  -> Incorrect message length or invalid format" ;;
                "14") print_warning "  -> Response too long" ;;
                "21") print_warning "  -> Busy repeat request" ;;
                "22") print_warning "  -> Conditions not correct" ;;
                "24") print_warning "  -> Request sequence error" ;;
                "25") print_warning "  -> No response from subnet component" ;;
                "26") print_warning "  -> Failure prevents execution of requested action" ;;
                "31") print_warning "  -> Request out of range" ;;
                "33") print_warning "  -> Security access denied" ;;
                "35") print_warning "  -> Invalid key" ;;
                "36") print_warning "  -> Exceed number of attempts" ;;
                "37") print_warning "  -> Required time delay not expired" ;;
                "70") print_warning "  -> Upload download not accepted" ;;
                "71") print_warning "  -> Transfer data suspended" ;;
                "72") print_warning "  -> General programming failure" ;;
                "73") print_warning "  -> Wrong block sequence counter" ;;
                "78") print_warning "  -> Request correctly received - response pending" ;;
                "7E") print_warning "  -> Sub-function not supported in active session" ;;
                "7F") print_warning "  -> Service not supported in active session" ;;
                *) print_warning "  -> Unknown NRC: 0x$nrc" ;;
            esac
        else
            local expected_response_sid=$(printf "%02X" $((0x$service_id + 0x40)))
            if [ "$response_sid" = "$expected_response_sid" ]; then
                print_success "Positive response confirmed!"
                print_success "Service 0x$service_id is ACTIVE"
            else
                print_warning "Unexpected response SID: 0x$response_sid"
            fi
        fi
        echo ""
        return 0
    else
        print_warning "No response received (timeout after ${TIMEOUT}s)"
        echo ""
        return 1
    fi
}

# Function to scan all UDS services with their sub-functions
scan_comprehensive_uds() {
    print_status "Starting comprehensive UDS service scan..."
    print_status "TX ID: 0x$TX_ID, RX ID: 0x$RX_ID"
    print_status "Padding: 0x$PADDING_BYTE"
    echo ""
    
    local active_services=0
    
    # Service 0x10: Diagnostic Session Control
    print_status "=== Service 0x10: Diagnostic Session Control ==="
    send_uds_message "10" "01" "" "Default Session" && ((active_services++))
    send_uds_message "10" "02" "" "Programming Session" && ((active_services++))
    send_uds_message "10" "03" "" "Extended Diagnostic Session" && ((active_services++))
    send_uds_message "10" "04" "" "Safety System Diagnostic Session" && ((active_services++))
    
    # Service 0x11: ECU Reset
    print_status "=== Service 0x11: ECU Reset ==="
    send_uds_message "11" "01" "" "Hard Reset" && ((active_services++))
    send_uds_message "11" "02" "" "Key Off On Reset" && ((active_services++))
    send_uds_message "11" "03" "" "Soft Reset" && ((active_services++))
    send_uds_message "11" "04" "" "Enable Rapid Power Shutdown" && ((active_services++))
    send_uds_message "11" "05" "" "Disable Rapid Power Shutdown" && ((active_services++))
    
    # Service 0x14: Clear Diagnostic Information
    print_status "=== Service 0x14: Clear Diagnostic Information ==="
    send_uds_message "14" "" "FFFFFF" "Clear All DTCs" && ((active_services++))
    
    # Service 0x19: Read DTC Information
    print_status "=== Service 0x19: Read DTC Information ==="
    send_uds_message "19" "01" "FF" "Report Number of DTC by Status Mask (All)" && ((active_services++))
    send_uds_message "19" "02" "FF" "Report DTC by Status Mask (All)" && ((active_services++))
    send_uds_message "19" "03" "" "Report DTC Snapshot Identification" && ((active_services++))
    send_uds_message "19" "04" "" "Report DTC Snapshot Record by DTC Number" && ((active_services++))
    send_uds_message "19" "05" "" "Report DTC Stored Data Record Number" && ((active_services++))
    send_uds_message "19" "06" "FF" "Report DTC by Severity Mask" && ((active_services++))
    send_uds_message "19" "07" "FF" "Report Number of DTC by Severity Mask" && ((active_services++))
    send_uds_message "19" "08" "FF" "Report DTC by Severity Mask Record" && ((active_services++))
    send_uds_message "19" "09" "" "Report Severity Information of DTC" && ((active_services++))
    send_uds_message "19" "0A" "" "Report Supported DTC" && ((active_services++))
    send_uds_message "19" "0B" "" "Report First Test Failed DTC" && ((active_services++))
    send_uds_message "19" "0C" "" "Report First Confirmed DTC" && ((active_services++))
    send_uds_message "19" "0D" "" "Report Most Recent Test Failed DTC" && ((active_services++))
    send_uds_message "19" "0E" "" "Report Most Recent Confirmed DTC" && ((active_services++))
    send_uds_message "19" "0F" "FF" "Report Mirror Memory DTC by Status Mask" && ((active_services++))
    
    # Service 0x22: Read Data By Identifier
    print_status "=== Service 0x22: Read Data By Identifier ==="
    # Common data identifiers
    send_uds_message "22" "" "F186" "Active Diagnostic Session Data Identifier" && ((active_services++))
    send_uds_message "22" "" "F190" "VIN Data Identifier" && ((active_services++))
    send_uds_message "22" "" "F197" "System Name or Engine Type" && ((active_services++))
    send_uds_message "22" "" "F18A" "ECU Serial Number" && ((active_services++))
    send_uds_message "22" "" "F18C" "ECU Manufacturing Date" && ((active_services++))
    send_uds_message "22" "" "F195" "ECU Installation Date" && ((active_services++))
    send_uds_message "22" "" "F1A2" "ECU Software Version Number" && ((active_services++))
    send_uds_message "22" "" "F1A3" "ECU Software Part Number" && ((active_services++))
    
    # Service 0x23: Read Memory By Address
    print_status "=== Service 0x23: Read Memory By Address ==="
    send_uds_message "23" "" "1100001000" "Read Memory (Address Format: 11, Length Format: 00, Address: 0010, Size: 00)" && ((active_services++))
    
    # Service 0x24: Read Scaling Data By Identifier
    print_status "=== Service 0x24: Read Scaling Data By Identifier ==="
    send_uds_message "24" "" "F190" "Read Scaling Data for VIN" && ((active_services++))
    
    # Service 0x27: Security Access
    print_status "=== Service 0x27: Security Access ==="
    send_uds_message "27" "01" "" "Request Seed (Level 1)" && ((active_services++))
    send_uds_message "27" "02" "" "Send Key (Level 1)" && ((active_services++))
    send_uds_message "27" "03" "" "Request Seed (Level 2)" && ((active_services++))
    send_uds_message "27" "04" "" "Send Key (Level 2)" && ((active_services++))
    send_uds_message "27" "05" "" "Request Seed (Level 3)" && ((active_services++))
    send_uds_message "27" "06" "" "Send Key (Level 3)" && ((active_services++))
    
    # Service 0x28: Communication Control
    print_status "=== Service 0x28: Communication Control ==="
    send_uds_message "28" "00" "03" "Enable Rx and Tx" && ((active_services++))
    send_uds_message "28" "01" "03" "Enable Rx and Disable Tx" && ((active_services++))
    send_uds_message "28" "02" "03" "Disable Rx and Enable Tx" && ((active_services++))
    send_uds_message "28" "03" "03" "Disable Rx and Tx" && ((active_services++))
    
    # Service 0x2A: Read Data By Periodic Identifier
    print_status "=== Service 0x2A: Read Data By Periodic Identifier ==="
    send_uds_message "2A" "01" "01F190" "Send At Slow Rate (VIN)" && ((active_services++))
    send_uds_message "2A" "02" "01F190" "Send At Medium Rate (VIN)" && ((active_services++))
    send_uds_message "2A" "03" "01F190" "Send At Fast Rate (VIN)" && ((active_services++))
    send_uds_message "2A" "04" "F190" "Stop Sending (VIN)" && ((active_services++))
    
    # Service 0x2C: Dynamically Define Data Identifier
    print_status "=== Service 0x2C: Dynamically Define Data Identifier ==="
    send_uds_message "2C" "01" "F200F19001" "Define By Identifier" && ((active_services++))
    send_uds_message "2C" "02" "F2001100001001" "Define By Memory Address" && ((active_services++))
    send_uds_message "2C" "03" "F200" "Clear Dynamically Defined Data Identifier" && ((active_services++))
    
    # Service 0x2E: Write Data By Identifier
    print_status "=== Service 0x2E: Write Data By Identifier ==="
    send_uds_message "2E" "" "F19000" "Write Data By Identifier (Test)" && ((active_services++))
    
    # Service 0x2F: Input Output Control By Identifier
    print_status "=== Service 0x2F: Input Output Control By Identifier ==="
    send_uds_message "2F" "" "F1900000" "Return Control To ECU" && ((active_services++))
    send_uds_message "2F" "" "F1900100" "Reset To Default" && ((active_services++))
    send_uds_message "2F" "" "F1900200" "Freeze Current State" && ((active_services++))
    send_uds_message "2F" "" "F19003FF00" "Short Term Adjustment" && ((active_services++))
    
    # Service 0x31: Routine Control
    print_status "=== Service 0x31: Routine Control ==="
    send_uds_message "31" "01" "0001" "Start Routine (ID: 0001)" && ((active_services++))
    send_uds_message "31" "02" "0001" "Stop Routine (ID: 0001)" && ((active_services++))
    send_uds_message "31" "03" "0001" "Request Routine Results (ID: 0001)" && ((active_services++))
    
    # Service 0x34: Request Download
    print_status "=== Service 0x34: Request Download ==="
    send_uds_message "34" "" "001100001000100" "Request Download" && ((active_services++))
    
    # Service 0x35: Request Upload
    print_status "=== Service 0x35: Request Upload ==="
    send_uds_message "35" "" "001100001000100" "Request Upload" && ((active_services++))
    
    # Service 0x36: Transfer Data
    print_status "=== Service 0x36: Transfer Data ==="
    send_uds_message "36" "" "01AABBCCDD" "Transfer Data (Block 1)" && ((active_services++))
    
    # Service 0x37: Request Transfer Exit
    print_status "=== Service 0x37: Request Transfer Exit ==="
    send_uds_message "37" "" "" "Request Transfer Exit" && ((active_services++))
    
    # Service 0x3D: Write Memory By Address
    print_status "=== Service 0x3D: Write Memory By Address ==="
    send_uds_message "3D" "" "110000100000" "Write Memory By Address" && ((active_services++))
    
    # Service 0x3E: Tester Present
    print_status "=== Service 0x3E: Tester Present ==="
    send_uds_message "3E" "00" "" "Tester Present (Response Required)" && ((active_services++))
    send_uds_message "3E" "80" "" "Tester Present (No Response)" && ((active_services++))
    
    # Service 0x83: Access Timing Parameter
    print_status "=== Service 0x83: Access Timing Parameter ==="
    send_uds_message "83" "01" "" "Read Extended Timing Parameter Set" && ((active_services++))
    send_uds_message "83" "02" "" "Set Timing Parameters To Default Values" && ((active_services++))
    send_uds_message "83" "03" "" "Read Currently Active Timing Parameters" && ((active_services++))
    send_uds_message "83" "04" "01021E" "Set Timing Parameters To Given Values" && ((active_services++))
    
    # Service 0x84: Secured Data Transmission
    print_status "=== Service 0x84: Secured Data Transmission ==="
    send_uds_message "84" "" "00AABBCCDD" "Secured Data Transmission" && ((active_services++))
    
    # Service 0x85: Control DTC Setting
    print_status "=== Service 0x85: Control DTC Setting ==="
    send_uds_message "85" "01" "" "DTC Setting On" && ((active_services++))
    send_uds_message "85" "02" "" "DTC Setting Off" && ((active_services++))
    
    # Service 0x86: Response On Event
    print_status "=== Service 0x86: Response On Event ==="
    send_uds_message "86" "00" "" "Stop Response On Event" && ((active_services++))
    send_uds_message "86" "01" "" "On DTC Status Change" && ((active_services++))
    send_uds_message "86" "03" "" "On Change Of Data Identifier" && ((active_services++))
    send_uds_message "86" "05" "" "Start Response On Event" && ((active_services++))
    send_uds_message "86" "06" "" "Clear Response On Event" && ((active_services++))
    
    # Service 0x87: Link Control
    print_status "=== Service 0x87: Link Control ==="
    send_uds_message "87" "01" "01" "Verify Baudrate Transition With Fixed Baudrate" && ((active_services++))
    send_uds_message "87" "02" "01" "Verify Baudrate Transition With Specific Baudrate" && ((active_services++))
    send_uds_message "87" "03" "01" "Transition Baudrate" && ((active_services++))
    
    echo ""
    print_success "Comprehensive UDS scan completed!"
    print_success "Total responses received: $active_services"
}

# Main execution
main() {
    echo "======================================================"
    echo "            Controller Service Scanner "
    echo "======================================================"
    echo ""
    
    # Check prerequisites
    if ! command -v cansend &> /dev/null; then
        print_error "can-utils not found. Please install: sudo apt install can-utils"
        exit 1
    fi
    
    check_can_interface
    
    print_status "CAN interface $CAN_INTERFACE is ready"
    echo ""
    
    # Trap Ctrl+C
    trap 'print_warning "Scan interrupted by user"; exit 0' INT
    
    scan_comprehensive_uds
    
    print_status "UDS scan completed successfully!"
}

# Run main function
main "$@"
