#!/bin/bash

#=============================================================================
# SSH Proxy Tunnel Setup Script
# This script sets up an SSH SOCKS5 proxy tunnel for a user
#=============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default variables
SSH_PORT=22
PROXY_PORT=1080
CONFIG_FILE="$HOME/.ssh_proxy_config"
LOG_FILE="/tmp/ssh_proxy_$(date +%Y%m%d).log"

#=============================================================================
# FUNCTIONS
#=============================================================================

print_banner() {
    clear
    echo -e "${BLUE}"
    echo "╔═══════════════════════════════════════════════════╗"
    echo "║         SSH SOCKS5 Proxy Tunnel Manager           ║"
    echo "╚═══════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

check_requirements() {
    echo -e "${YELLOW}[*] Checking requirements...${NC}"
    
    # Check if ssh is installed
    if ! command -v ssh &> /dev/null; then
        echo -e "${RED}[!] SSH client not found! Please install openssh-client${NC}"
        exit 1
    fi
    
    # Check if autossh is installed (optional, for persistent connections)
    if command -v autossh &> /dev/null; then
        AUTOSSH_AVAILABLE=true
        echo -e "${GREEN}[✓] autossh detected - persistent connections available${NC}"
    else
        AUTOSSH_AVAILABLE=false
        echo -e "${YELLOW}[!] autossh not found - install with: sudo apt install autossh${NC}"
        echo -e "${YELLOW}    Standard SSH will be used instead${NC}"
    fi
}

setup_new_user() {
    print_banner
    echo -e "${BLUE}[+] Creating new proxy user${NC}"
    echo ""
    
    # Get user details
    read -p "Enter username for proxy: " PROXY_USER
    read -p "Enter password for $PROXY_USER: " -s PROXY_PASS
    echo ""
    
    echo -e "${YELLOW}[*] Creating user $PROXY_USER...${NC}"
    
    # Create user with restricted shell
    sudo useradd -m -s /bin/false "$PROXY_USER" 2>/dev/null
    
    # Set password
    echo "$PROXY_USER:$PROXY_PASS" | sudo chpasswd
    
    # Create .ssh directory
    sudo mkdir -p "/home/$PROXY_USER/.ssh"
    sudo chmod 700 "/home/$PROXY_USER/.ssh"
    sudo chown -R "$PROXY_USER:$PROXY_USER" "/home/$PROXY_USER"
    
    echo -e "${GREEN}[✓] User $PROXY_USER created successfully${NC}"
    
    # Ask if they want to add SSH key
    echo ""
    read -p "Do you want to add an SSH public key for this user? (y/n): " ADD_KEY
    if [[ "$ADD_KEY" == "y" ]]; then
        echo -e "${YELLOW}Paste the SSH public key (or path to key file):${NC}"
        read -p "> " KEY_INPUT
        
        if [[ -f "$KEY_INPUT" ]]; then
            sudo cat "$KEY_INPUT" >> "/home/$PROXY_USER/.ssh/authorized_keys"
        else
            sudo echo "$KEY_INPUT" >> "/home/$PROXY_USER/.ssh/authorized_keys"
        fi
        
        sudo chmod 600 "/home/$PROXY_USER/.ssh/authorized_keys"
        sudo chown -R "$PROXY_USER:$PROXY_USER" "/home/$PROXY_USER/.ssh"
        echo -e "${GREEN}[✓] SSH key added${NC}"
    fi
    
    # Save configuration
    echo "USER=$PROXY_USER" > "$CONFIG_FILE"
    echo "PORT=$PROXY_PORT" >> "$CONFIG_FILE"
    
    echo -e "${GREEN}[✓] User configuration saved${NC}"
}

configure_existing_user() {
    print_banner
    echo -e "${BLUE}[+] Configure existing user for proxy${NC}"
    echo ""
    
    read -p "Enter existing username: " PROXY_USER
    
    # Check if user exists
    if ! id "$PROXY_USER" &>/dev/null; then
        echo -e "${RED}[!] User $PROXY_USER does not exist!${NC}"
        read -p "Create new user? (y/n): " CREATE_NEW
        if [[ "$CREATE_NEW" == "y" ]]; then
            setup_new_user
        else
            return 1
        fi
    else
        # Ensure user has restricted shell for proxy-only access
        read -p "Restrict user to proxy-only access? (y/n): " RESTRICT
        if [[ "$RESTRICT" == "y" ]]; then
            sudo usermod -s /bin/false "$PROXY_USER"
            echo -e "${GREEN}[✓] User restricted to proxy-only${NC}"
        fi
        
        echo "USER=$PROXY_USER" > "$CONFIG_FILE"
        echo "PORT=$PROXY_PORT" >> "$CONFIG_FILE"
        echo -e "${GREEN}[✓] Configuration saved${NC}"
    fi
}

start_proxy_server() {
    # Load config if exists
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        echo -e "${RED}[!] No configuration found. Run setup first!${NC}"
        return 1
    fi
    
    print_banner
    echo -e "${BLUE}[+] Starting SSH SOCKS5 Proxy Server${NC}"
    echo ""
    
    # Get server IP
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    # Read port from config or use default
    PROXY_PORT=${PORT:-1080}
    
    echo -e "${YELLOW}[*] Configuration:${NC}"
    echo -e "    User: ${GREEN}$USER${NC}"
    echo -e "    Server IP: ${GREEN}$SERVER_IP${NC}"
    echo -e "    Proxy Port: ${GREEN}$PROXY_PORT${NC}"
    echo ""
    
    # Check SSH server configuration
    echo -e "${YELLOW}[*] Checking SSH server configuration...${NC}"
    
    # Enable TCP forwarding if not already enabled
    if ! grep -q "^AllowTcpForwarding yes" /etc/ssh/sshd_config; then
        echo -e "${YELLOW}[!] TCP forwarding might not be enabled${NC}"
        read -p "Enable TCP forwarding in SSH config? (y/n): " ENABLE_TCP
        if [[ "$ENABLE_TCP" == "y" ]]; then
            echo "AllowTcpForwarding yes" | sudo tee -a /etc/ssh/sshd_config
            sudo systemctl restart sshd
            echo -e "${GREEN}[✓] TCP forwarding enabled${NC}"
        fi
    fi
    
    # Start proxy tunnel
    echo -e "${YELLOW}[*] Starting proxy tunnel...${NC}"
    echo -e "${YELLOW}[*] Log file: $LOG_FILE${NC}"
    echo ""
    
    if [[ "$AUTOSSH_AVAILABLE" == true ]]; then
        # Using autossh for persistent connection
        AUTOSSH_PIDFILE="/tmp/ssh_proxy_${USER}.pid"
        AUTOSSH_LOGFILE="$LOG_FILE"
        
        autossh -M 20000 -f -N -D "0.0.0.0:$PROXY_PORT" \
            -o "ServerAliveInterval 30" \
            -o "ServerAliveCountMax 3" \
            -o "StrictHostKeyChecking=no" \
            "$USER@localhost" \
            >> "$LOG_FILE" 2>&1
            
        if [[ $? -eq 0 ]]; then
            echo $! > "$AUTOSSH_PIDFILE"
            echo -e "${GREEN}[✓] Proxy started with autossh (persistent)${NC}"
        else
            echo -e "${RED}[!] Failed to start proxy${NC}"
            return 1
        fi
    else
        # Using standard SSH
        ssh -f -N -D "0.0.0.0:$PROXY_PORT" \
            -o "ServerAliveInterval 30" \
            -o "ServerAliveCountMax 3" \
            -o "StrictHostKeyChecking=no" \
            "$USER@localhost" \
            >> "$LOG_FILE" 2>&1
            
        if [[ $? -eq 0 ]]; then
            echo -e "${GREEN}[✓] Proxy started successfully${NC}"
        else
            echo -e "${RED}[!] Failed to start proxy${NC}"
            return 1
        fi
    fi
    
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Proxy Server is Running!${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "${YELLOW}  Connection details for clients:${NC}"
    echo -e "  ┌─────────────────────────────────────────────┐"
    echo -e "  │  Type:     ${GREEN}SOCKS5${NC}                           │"
    echo -e "  │  Host:     ${GREEN}$SERVER_IP${NC}              │"
    echo -e "  │  Port:     ${GREEN}$PROXY_PORT${NC}                          │"
    echo -e "  │  User:     ${GREEN}$USER${NC}                        │"
    echo -e "  └─────────────────────────────────────────────┘"
    echo ""
    echo -e "${YELLOW}  Client setup examples:${NC}"
    echo ""
    echo -e "  ${BLUE}Firefox/Chrome:${NC}"
    echo -e "  Settings → Network → Proxy → Manual"
    echo -e "  SOCKS Host: $SERVER_IP  Port: $PROXY_PORT"
    echo -e "  SOCKS v5"
    echo ""
    echo -e "  ${BLUE}Terminal (Linux/Mac):${NC}"
    echo -e "  export ALL_PROXY=socks5://$USER@$SERVER_IP:$PROXY_PORT"
    echo ""
    echo -e "  ${BLUE}Proxychains:${NC}"
    echo -e "  Add to /etc/proxychains.conf:"
    echo -e "  socks5 $SERVER_IP $PROXY_PORT"
    echo ""
    echo -e "${YELLOW}[*] Press Ctrl+C to stop the proxy (if running in foreground)${NC}"
}

stop_proxy() {
    print_banner
    echo -e "${RED}[+] Stopping SSH Proxy${NC}"
    echo ""
    
    # Load config
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
    
    PROXY_USER=${USER:-"proxy"}
    
    # Kill SSH tunnel processes
    echo -e "${YELLOW}[*] Stopping proxy processes...${NC}"
    
    # Find and kill ssh processes with dynamic forwarding
    PIDS=$(ps aux | grep "ssh.*-D.*$PROXY_PORT" | grep -v grep | awk '{print $2}')
    
    if [[ -z "$PIDS" ]]; then
        echo -e "${YELLOW}[!] No active proxy found on port $PROXY_PORT${NC}"
    else
        for PID in $PIDS; do
            kill -9 $PID 2>/dev/null
            echo -e "${GREEN}[✓] Killed process $PID${NC}"
        done
    fi
    
    # Kill autossh if present
    AUTOSSH_PIDS=$(ps aux | grep "autossh" | grep -v grep | awk '{print $2}')
    if [[ ! -z "$AUTOSSH_PIDS" ]]; then
        for PID in $AUTOSSH_PIDS; do
            kill -9 $PID 2>/dev/null
        done
    fi
    
    # Remove PID file
    rm -f "/tmp/ssh_proxy_*.pid"
    
    echo -e "${GREEN}[✓] Proxy stopped${NC}"
}

show_status() {
    print_banner
    echo -e "${BLUE}[+] Proxy Status${NC}"
    echo ""
    
    # Load config
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
    
    PROXY_PORT=${PORT:-1080}
    
    # Check if proxy is running
    if ps aux | grep "ssh.*-D.*$PROXY_PORT" | grep -v grep > /dev/null; then
        echo -e "${GREEN}[✓] Proxy is RUNNING${NC}"
        echo ""
        echo -e "${YELLOW}Active connections:${NC}"
        ps aux | grep "ssh.*-D.*$PROXY_PORT" | grep -v grep
        echo ""
        echo -e "${YELLOW}Listening on port:${NC}"
        sudo netstat -tlnp | grep ":$PROXY_PORT" 2>/dev/null || ss -tlnp | grep ":$PROXY_PORT"
    else
        echo -e "${RED}[!] Proxy is NOT running${NC}"
    fi
}

show_client_guide() {
    print_banner
    echo -e "${BLUE}[+] Client Setup Guide${NC}"
    echo ""
    
    SERVER_IP=$(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    fi
    PROXY_PORT=${PORT:-1080}
    
    echo -e "${YELLOW}=== Windows Setup ===${NC}"
    echo ""
    echo "1. Firefox:"
    echo "   Options → General → Network Settings → Manual proxy configuration"
    echo "   SOCKS Host: $SERVER_IP"
    echo "   Port: $PROXY_PORT"
    echo "   Select: SOCKS v5"
    echo ""
    echo "2. Chrome:"
    echo "   Settings → Advanced → System → Open proxy settings"
    echo "   Or use extension: SwitchyOmega"
    echo ""
    echo "3. Proxifier (for all apps):"
    echo "   Profile → Proxy Servers → Add"
    echo "   Address: $SERVER_IP"
    echo "   Port: $PROXY_PORT"
    echo "   Protocol: SOCKS Version 5"
    echo ""
    echo -e "${YELLOW}=== Linux Setup ===${NC}"
    echo ""
    echo "1. System-wide proxy:"
    echo "   export ALL_PROXY=socks5://$SERVER_IP:$PROXY_PORT"
    echo ""
    echo "2. proxychains:"
    echo "   Edit /etc/proxychains.conf and add:"
    echo "   socks5 $SERVER_IP $PROXY_PORT"
    echo "   Then use: proxychains firefox"
    echo ""
    echo "3. SSH tunnel from another machine:"
    echo "   ssh -D 1080 -N -f user@$SERVER_IP"
    echo ""
    echo -e "${YELLOW}=== Android Setup ===${NC}"
    echo ""
    echo "1. Install 'Postern' or 'Drony' from Play Store"
    echo "2. Configure SOCKS5 proxy:"
    echo "   Server: $SERVER_IP"
    echo "   Port: $PROXY_PORT"
    echo ""
    echo -e "${YELLOW}=== iOS Setup ===${NC}"
    echo ""
    echo "1. Settings → Wi-Fi → (i) → Configure Proxy → Manual"
    echo "2. Server: $SERVER_IP"
    echo "3. Port: $PROXY_PORT"
    echo ""
}

monitor_traffic() {
    print_banner
    echo -e "${BLUE}[+] Real-time Traffic Monitor${NC}"
    echo -e "${YELLOW}[*] Press Ctrl+C to stop monitoring${NC}"
    echo ""
    
    # Show real-time connections
    watch -n 1 "echo 'Active SSH Proxy Connections:'; netstat -an | grep ':1080' | grep ESTABLISHED; echo ''; echo 'Process:'; ps aux | grep 'ssh.*-D' | grep -v grep"
}

#=============================================================================
# MAIN MENU
#=============================================================================

main_menu() {
    while true; do
        print_banner
        echo -e "${YELLOW}Main Menu:${NC}"
        echo ""
        echo "  1) Setup New Proxy User"
        echo "  2) Configure Existing User"
        echo "  3) Start Proxy Server"
        echo "  4) Stop Proxy Server"
        echo "  5) Show Proxy Status"
        echo "  6) Monitor Traffic"
        echo "  7) Client Setup Guide"
        echo "  8) Change Proxy Port"
        echo "  0) Exit"
        echo ""
        read -p "Select option [0-8]: " OPTION
        
        case $OPTION in
            1)
                setup_new_user
                read -p "Press Enter to continue..."
                ;;
            2)
                configure_existing_user
                read -p "Press Enter to continue..."
                ;;
            3)
                start_proxy_server
                read -p "Press Enter to continue..."
                ;;
            4)
                stop_proxy
                read -p "Press Enter to continue..."
                ;;
            5)
                show_status
                read -p "Press Enter to continue..."
                ;;
            6)
                monitor_traffic
                ;;
            7)
                show_client_guide
                read -p "Press Enter to continue..."
                ;;
            8)
                read -p "Enter new proxy port: " NEW_PORT
                if [[ -f "$CONFIG_FILE" ]]; then
                    sed -i "s/PORT=.*/PORT=$NEW_PORT/" "$CONFIG_FILE"
                fi
                echo -e "${GREEN}[✓] Port changed to $NEW_PORT${NC}"
                read -p "Press Enter to continue..."
                ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}[!] Invalid option${NC}"
                read -p "Press Enter to continue..."
                ;;
        esac
    done
}

#=============================================================================
# SCRIPT START
#=============================================================================

# Check if running as root (required for user management)
if [[ "$EUID" -ne 0 ]] && [[ "$1" != "client" ]]; then
    echo -e "${YELLOW}[!] Some features require root privileges${NC}"
    echo -e "${YELLOW}[!] Running in limited mode${NC}"
    echo ""
fi

# Initial setup
check_requirements

# Handle command line arguments
case "$1" in
    "start")
        start_proxy_server
        ;;
    "stop")
        stop_proxy
        ;;
    "status")
        show_status
        ;;
    "setup")
        setup_new_user
        ;;
    "monitor")
        monitor_traffic
        ;;
    "guide")
        show_client_guide
        ;;
    *)
        main_menu
        ;;
esac
