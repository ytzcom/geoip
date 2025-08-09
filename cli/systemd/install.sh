#!/usr/bin/env bash
#
# Install script for GeoIP Update systemd service
#
# This script:
# - Creates necessary user and directories
# - Installs the update script
# - Configures systemd service and timer
# - Sets up proper permissions
#

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_USER="geoip"
SERVICE_GROUP="geoip"
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/geoip-update"
DATA_DIR="/var/lib/geoip"
LOG_DIR="/var/log/geoip"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Helper functions
info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
    exit 1
}

# Check if running as root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)"
    fi
}

# Detect which script to install
select_script() {
    info "Select the GeoIP update script to install:"
    echo "1) Bash script (geoip-update.sh)"
    echo "2) Python script (geoip-update.py)"
    echo "3) Go binary (geoip-update)"
    read -p "Enter choice [1-3]: " choice

    case $choice in
        1)
            SCRIPT_TYPE="bash"
            SCRIPT_NAME="geoip-update.sh"
            SCRIPT_SOURCE="../geoip-update.sh"
            ;;
        2)
            SCRIPT_TYPE="python"
            SCRIPT_NAME="geoip-update.py"
            SCRIPT_SOURCE="../geoip-update.py"
            ;;
        3)
            SCRIPT_TYPE="go"
            SCRIPT_NAME="geoip-update"
            SCRIPT_SOURCE="../go/build/geoip-update"
            if [[ ! -f "$SCRIPT_DIR/$SCRIPT_SOURCE" ]]; then
                warn "Go binary not found. Building it now..."
                (cd "$SCRIPT_DIR/../go" && make build)
                SCRIPT_SOURCE="../go/geoip-update"
            fi
            ;;
        *)
            error "Invalid choice"
            ;;
    esac

    if [[ ! -f "$SCRIPT_DIR/$SCRIPT_SOURCE" ]]; then
        error "Script not found: $SCRIPT_DIR/$SCRIPT_SOURCE"
    fi
}

# Create system user
create_user() {
    if id "$SERVICE_USER" &>/dev/null; then
        info "User $SERVICE_USER already exists"
    else
        info "Creating system user: $SERVICE_USER"
        useradd --system --home-dir "$DATA_DIR" --shell /bin/false "$SERVICE_USER"
    fi
}

# Create directories
create_directories() {
    info "Creating directories..."
    
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$DATA_DIR"
    mkdir -p "$LOG_DIR"
    
    # Set ownership
    chown "$SERVICE_USER:$SERVICE_GROUP" "$DATA_DIR"
    chown "$SERVICE_USER:$SERVICE_GROUP" "$LOG_DIR"
    
    # Set permissions
    chmod 755 "$CONFIG_DIR"
    chmod 755 "$DATA_DIR"
    chmod 755 "$LOG_DIR"
}

# Install script
install_script() {
    info "Installing $SCRIPT_NAME to $INSTALL_DIR..."
    
    cp "$SCRIPT_DIR/$SCRIPT_SOURCE" "$INSTALL_DIR/$SCRIPT_NAME"
    chmod 755 "$INSTALL_DIR/$SCRIPT_NAME"
    
    # For Python script, also install requirements
    if [[ "$SCRIPT_TYPE" == "python" ]]; then
        if command -v pip3 &>/dev/null; then
            info "Installing Python dependencies..."
            pip3 install -r "$SCRIPT_DIR/../requirements.txt"
        else
            warn "pip3 not found. Please install Python dependencies manually."
        fi
    fi
    
    # For Bash script, check dependencies
    if [[ "$SCRIPT_TYPE" == "bash" ]]; then
        if ! command -v jq &>/dev/null; then
            warn "jq is not installed. Installing it now..."
            if command -v apt-get &>/dev/null; then
                apt-get update && apt-get install -y jq
            elif command -v yum &>/dev/null; then
                yum install -y jq
            else
                error "Please install jq manually"
            fi
        fi
    fi
}

# Configure systemd service
configure_systemd() {
    info "Configuring systemd service..."
    
    # Update service file with correct script path
    cp "$SCRIPT_DIR/geoip-update.service" /tmp/geoip-update.service
    
    # Comment out all ExecStart lines first
    sed -i 's/^ExecStart=/#ExecStart=/' /tmp/geoip-update.service
    
    # Uncomment the appropriate ExecStart line
    case $SCRIPT_TYPE in
        bash)
            sed -i "s|#ExecStart=/usr/local/bin/geoip-update.sh|ExecStart=/usr/local/bin/geoip-update.sh|" /tmp/geoip-update.service
            ;;
        python)
            sed -i "s|#ExecStart=/usr/local/bin/python3|ExecStart=/usr/local/bin/python3|" /tmp/geoip-update.service
            ;;
        go)
            sed -i "s|#ExecStart=/usr/local/bin/geoip-update -quiet|ExecStart=/usr/local/bin/geoip-update -quiet|" /tmp/geoip-update.service
            ;;
    esac
    
    # Install service and timer
    cp /tmp/geoip-update.service /etc/systemd/system/
    cp "$SCRIPT_DIR/geoip-update.timer" /etc/systemd/system/
    
    # Reload systemd
    systemctl daemon-reload
}

# Setup configuration
setup_config() {
    if [[ -f "$CONFIG_DIR/config" ]]; then
        warn "Configuration already exists at $CONFIG_DIR/config"
    else
        info "Creating configuration file..."
        cp "$SCRIPT_DIR/config.example" "$CONFIG_DIR/config"
        chmod 600 "$CONFIG_DIR/config"
        
        warn "Please edit $CONFIG_DIR/config and add your API key"
        read -p "Press Enter to continue..."
        
        # Try to open in editor
        if [[ -n "${EDITOR:-}" ]]; then
            $EDITOR "$CONFIG_DIR/config"
        else
            nano "$CONFIG_DIR/config" || vi "$CONFIG_DIR/config"
        fi
    fi
}

# Enable and start service
enable_service() {
    info "Enabling systemd timer..."
    systemctl enable geoip-update.timer
    
    read -p "Do you want to start the timer now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        systemctl start geoip-update.timer
        info "Timer started. Next run:"
        systemctl list-timers geoip-update.timer
    fi
    
    read -p "Do you want to run the update once now? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "Running update..."
        systemctl start geoip-update.service
        journalctl -u geoip-update.service -f
    fi
}

# Display summary
show_summary() {
    echo
    info "Installation complete!"
    echo
    echo "Service user:    $SERVICE_USER"
    echo "Data directory:  $DATA_DIR"
    echo "Log directory:   $LOG_DIR"
    echo "Config file:     $CONFIG_DIR/config"
    echo "Script:          $INSTALL_DIR/$SCRIPT_NAME"
    echo
    echo "Useful commands:"
    echo "  systemctl status geoip-update.timer    # Check timer status"
    echo "  systemctl start geoip-update.service   # Run update manually"
    echo "  journalctl -u geoip-update.service     # View logs"
    echo "  systemctl list-timers geoip-update     # See next run time"
    echo
}

# Main installation flow
main() {
    check_root
    
    info "GeoIP Update Systemd Service Installer"
    echo
    
    select_script
    create_user
    create_directories
    install_script
    configure_systemd
    setup_config
    enable_service
    show_summary
}

# Run main function
main "$@"