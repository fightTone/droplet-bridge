#!/bin/bash

# SSH Tunnel Server - Interactive terminal application
# Creates reverse tunnel from home PC to DigitalOcean droplet
# GitHub: https://github.com/username/ssh-tunnel-manager

set -e

# Configuration files
CONFIG_DIR="$HOME/.ssh-tunnel"
CONFIG_FILE="$CONFIG_DIR/server.conf"
LOG_FILE="$CONFIG_DIR/tunnel_server.log"
PID_FILE="$CONFIG_DIR/tunnel_server.pid"

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

# Terminal colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color

# Function to print banner
print_banner() {
    clear
    echo -e "${PURPLE}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    SSH Tunnel Server                        ║"
    echo "║            Home PC to Droplet Reverse Tunnel               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# Function to print colored messages
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Function to log messages
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# Function to load configuration
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
        return 0
    fi
    return 1
}

# Function to save configuration
save_config() {
    cat > "$CONFIG_FILE" << EOF
# SSH Tunnel Server Configuration
DROPLET_USER="$DROPLET_USER"
DROPLET_IP="$DROPLET_IP"
REMOTE_PORT="$REMOTE_PORT"
LOCAL_PORT="$LOCAL_PORT"
LOCAL_USER="$LOCAL_USER"
EOF
    print_success "Configuration saved to $CONFIG_FILE"
}

# Function to get user input with default value
get_input() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    
    if [ -n "$default" ]; then
        echo -ne "${WHITE}$prompt${NC} ${YELLOW}[$default]${NC}: "
    else
        echo -ne "${WHITE}$prompt${NC}: "
    fi
    
    read -r input
    if [ -z "$input" ] && [ -n "$default" ]; then
        input="$default"
    fi
    
    eval "$var_name='$input'"
}

# Function to configure connection settings
configure_connection() {
    print_banner
    echo -e "${PURPLE}Reverse Tunnel Configuration${NC}"
    echo "================================================"
    echo
    
    # Load existing config if available
    if load_config; then
        print_info "Found existing configuration"
        echo
    fi
    
    get_input "Droplet Username" "$DROPLET_USER" "DROPLET_USER"
    get_input "Droplet IP Address" "$DROPLET_IP" "DROPLET_IP"
    get_input "Remote Port (on droplet)" "$REMOTE_PORT" "REMOTE_PORT"
    get_input "Local Port (SSH on this PC)" "$LOCAL_PORT" "LOCAL_PORT"
    get_input "Local Username (this PC)" "$LOCAL_USER" "LOCAL_USER"
    
    echo
    echo -e "${YELLOW}Configuration Summary:${NC}"
    echo "├─ Droplet: $DROPLET_USER@$DROPLET_IP"
    echo "├─ Remote Port: $REMOTE_PORT"
    echo "├─ Local Port: $LOCAL_PORT"
    echo "└─ Local User: $LOCAL_USER"
    echo
    print_info "Clients will connect: ssh -p $REMOTE_PORT localhost (from droplet)"
    echo
    
    echo -ne "${WHITE}Save this configuration? (y/n)${NC}: "
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        save_config
        DROPLET_USER_IP="$DROPLET_USER@$DROPLET_IP"
    else
        print_warning "Configuration not saved"
        return 1
    fi
}

# Function to check if tunnel is active
is_tunnel_active() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            # Additional check: verify SSH process is actually running
            if ps -p "$pid" -o args | grep -q "ssh.*-R"; then
                return 0
            fi
        fi
    fi
    return 1
}

# Function to start reverse tunnel
start_tunnel() {
    if [ -z "$DROPLET_USER_IP" ]; then
        print_error "No configuration found. Please configure connection first."
        return 1
    fi
    
    print_info "Starting reverse SSH tunnel: home_pc:$LOCAL_PORT -> $DROPLET_USER_IP:$REMOTE_PORT"
    log "Starting reverse SSH tunnel: home_pc:$LOCAL_PORT -> $DROPLET_USER_IP:$REMOTE_PORT"
    
    # Start reverse SSH tunnel with auto-reconnection options
    ssh -fN \
        -R "$REMOTE_PORT:localhost:$LOCAL_PORT" \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o ExitOnForwardFailure=yes \
        -o StrictHostKeyChecking=no \
        -o GatewayPorts=yes \
        "$DROPLET_USER_IP" \
        && echo $! > "$PID_FILE"
    
    if [ $? -eq 0 ]; then
        print_success "Reverse tunnel started successfully (PID: $(cat $PID_FILE 2>/dev/null))"
        print_info "Home PC accessible via: ssh -p $REMOTE_PORT $LOCAL_USER@localhost (from droplet)"
        log "Reverse tunnel started successfully (PID: $(cat $PID_FILE 2>/dev/null))"
    else
        print_error "Failed to start reverse tunnel"
        log "Failed to start reverse tunnel"
        return 1
    fi
}

# Function to stop tunnel
stop_tunnel() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null 2>&1; then
            kill "$pid"
            print_success "Stopped reverse tunnel (PID: $pid)"
            log "Stopped reverse tunnel (PID: $pid)"
        else
            print_warning "Tunnel process not found"
        fi
        rm -f "$PID_FILE"
    else
        print_warning "No tunnel PID file found"
    fi
    
    # Kill any remaining SSH processes that might be hanging
    if pkill -f "ssh.*-R.*$REMOTE_PORT:localhost:$LOCAL_PORT.*$DROPLET_USER_IP" 2>/dev/null; then
        print_info "Cleaned up hanging SSH processes"
    fi
}

# Function to monitor and restart tunnel
monitor_tunnel() {
    if [ -z "$DROPLET_USER_IP" ]; then
        print_error "No configuration found. Please configure connection first."
        return 1
    fi
    
    print_info "Starting reverse tunnel monitor..."
    print_warning "Press Ctrl+C to stop monitoring"
    log "Starting reverse tunnel monitor..."
    
    # Trap Ctrl+C to gracefully exit
    trap 'print_warning "Monitor stopped by user"; exit 0' INT
    
    while true; do
        if ! is_tunnel_active; then
            print_warning "Reverse tunnel is down, attempting to restart..."
            log "Reverse tunnel is down, attempting to restart..."
            stop_tunnel
            sleep 5
            start_tunnel
        else
            print_success "Reverse tunnel is active ($(date '+%H:%M:%S'))"
        fi
        sleep 60  # Check every minute
    done
}

# Function to show main menu
show_menu() {
    print_banner
    
    # Load config and show status
    if load_config; then
        echo -e "${GREEN}Current Configuration:${NC}"
        echo "├─ Droplet: $DROPLET_USER@$DROPLET_IP"
        echo "├─ Remote Port: $REMOTE_PORT"
        echo "└─ Local User: $LOCAL_USER"
        DROPLET_USER_IP="$DROPLET_USER@$DROPLET_IP"
    else
        print_warning "No configuration found - please configure first"
    fi
    
    echo
    if is_tunnel_active; then
        echo -e "${GREEN}Status: Reverse Tunnel ACTIVE (PID: $(cat $PID_FILE))${NC}"
        echo -e "${CYAN}Access from droplet: ssh -p $REMOTE_PORT $LOCAL_USER@localhost${NC}"
    else
        echo -e "${RED}Status: Reverse Tunnel INACTIVE${NC}"
    fi
    
    echo
    echo -e "${WHITE}Options:${NC}"
    echo "1) Start Reverse Tunnel"
    echo "2) Stop Reverse Tunnel"
    echo "3) Restart Reverse Tunnel"
    echo "4) Monitor Tunnel (Auto-reconnect)"
    echo "5) Configure Connection"
    echo "6) View Status"
    echo "7) View Logs"
    echo "8) Setup Systemd Service"
    echo "9) Exit"
    echo
    echo -ne "${WHITE}Choose option [1-9]${NC}: "
}

# Function to view status
view_status() {
    print_banner
    echo -e "${PURPLE}Reverse Tunnel Status${NC}"
    echo "================================================"
    
    if is_tunnel_active; then
        local pid=$(cat "$PID_FILE")
        print_success "Reverse tunnel is ACTIVE"
        echo "├─ PID: $pid"
        echo "├─ Started: $(ps -p $pid -o lstart= 2>/dev/null || echo 'Unknown')"
        echo "├─ Remote Port: $REMOTE_PORT"
        echo "└─ Access: ssh -p $REMOTE_PORT $LOCAL_USER@localhost (from droplet)"
    else
        print_error "Reverse tunnel is INACTIVE"
    fi
    
    echo
    echo -ne "${WHITE}Press Enter to continue...${NC}"
    read -r
}

# Function to view logs
view_logs() {
    print_banner
    echo -e "${PURPLE}Recent Logs${NC}"
    echo "================================================"
    
    if [ -f "$LOG_FILE" ]; then
        tail -20 "$LOG_FILE"
    else
        print_warning "No log file found"
    fi
    
    echo
    echo -ne "${WHITE}Press Enter to continue...${NC}"
    read -r
}

# Function to setup systemd service for auto-start
setup_service() {
    print_banner
    echo -e "${PURPLE}Systemd Service Setup${NC}"
    echo "================================================"
    
    local service_name="ssh-reverse-tunnel"
    local service_file="/etc/systemd/system/${service_name}.service"
    
    if [ "$EUID" -ne 0 ]; then
        print_error "Please run with sudo to setup systemd service"
        print_info "Usage: sudo $0 setup-service"
        return 1
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        print_error "No configuration found. Please configure first."
        return 1
    fi
    
    print_info "Creating systemd service..."
    
    cat > "$service_file" << EOF
[Unit]
Description=SSH Reverse Tunnel to DigitalOcean Droplet
After=network.target

[Service]
Type=simple
User=$(logname)
ExecStart=$(realpath "$0") monitor
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$service_name"
    
    print_success "Systemd service created and enabled: $service_name"
    print_info "Start with: sudo systemctl start $service_name"
    print_info "Check status: sudo systemctl status $service_name"
    print_info "View logs: journalctl -u $service_name -f"
    
    log "Systemd service created and enabled: $service_name"
    
    echo
    echo -ne "${WHITE}Start the service now? (y/n)${NC}: "
    read -r start_now
    if [[ "$start_now" =~ ^[Yy]$ ]]; then
        systemctl start "$service_name"
        print_success "Service started!"
        systemctl status "$service_name" --no-pager
    fi
    
    echo
    echo -ne "${WHITE}Press Enter to continue...${NC}"
    read -r
}

# Initialize default values
REMOTE_PORT="2222"
LOCAL_PORT="22"
LOCAL_USER="$(whoami)"

# Load existing configuration (don't exit on failure)
load_config || true

# Main script logic
case "${1:-menu}" in
    start)
        if [ -z "$DROPLET_USER_IP" ]; then
            configure_connection || exit 1
        fi
        if is_tunnel_active; then
            print_warning "Reverse tunnel is already active"
            exit 0
        fi
        start_tunnel
        ;;
    stop)
        stop_tunnel
        ;;
    restart)
        if [ -z "$DROPLET_USER_IP" ]; then
            configure_connection || exit 1
        fi
        stop_tunnel
        sleep 2
        start_tunnel
        ;;
    monitor)
        monitor_tunnel
        ;;
    status)
        view_status
        ;;
    config|configure)
        configure_connection
        ;;
    logs)
        view_logs
        ;;
    setup-service)
        setup_service
        ;;
    menu|*)
        # Interactive menu mode
        while true; do
            show_menu
            read -r choice
            
            case $choice in
                1)
                    if [ -z "$DROPLET_USER_IP" ]; then
                        configure_connection || continue
                    fi
                    if is_tunnel_active; then
                        print_warning "Reverse tunnel is already active"
                    else
                        start_tunnel
                    fi
                    echo
                    echo -ne "${WHITE}Press Enter to continue...${NC}"
                    read -r
                    ;;
                2)
                    stop_tunnel
                    echo
                    echo -ne "${WHITE}Press Enter to continue...${NC}"
                    read -r
                    ;;
                3)
                    if [ -z "$DROPLET_USER_IP" ]; then
                        configure_connection || continue
                    fi
                    stop_tunnel
                    sleep 2
                    start_tunnel
                    echo
                    echo -ne "${WHITE}Press Enter to continue...${NC}"
                    read -r
                    ;;
                4)
                    monitor_tunnel
                    ;;
                5)
                    configure_connection
                    echo
                    echo -ne "${WHITE}Press Enter to continue...${NC}"
                    read -r
                    ;;
                6)
                    view_status
                    ;;
                7)
                    view_logs
                    ;;
                8)
                    setup_service
                    ;;
                9)
                    print_info "Goodbye!"
                    exit 0
                    ;;
                *)
                    print_error "Invalid option. Please choose 1-9."
                    sleep 2
                    ;;
            esac
        done
        ;;
esac