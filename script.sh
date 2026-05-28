#!/bin/bash
#=============================================================================
# SSH SOCKS5 Proxy Manager - Stable Release
# GitHub: jamalghaffari/ssh-proxy-script
#=============================================================================

set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# Config paths
CONFIG_DIR="$HOME/.ssh_proxy"
CONFIG_FILE="$CONFIG_DIR/config"
CRED_FILE="$CONFIG_DIR/credentials.txt"
PROXY_PORT="1080"

mkdir -p "$CONFIG_DIR"

#=============================================================================
# UTILITY FUNCTIONS
#=============================================================================

banner() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════╗"
    echo "║         SSH SOCKS5 Proxy Manager             ║"
    echo "║         github.com/jamalghaffari             ║"
    echo "╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

get_public_ip() {
    curl -4 -s ifconfig.me || curl -4 -s icanhazip.com || curl -4 -s ipinfo.io/ip || hostname -I | awk '{print $1}'
}

gen_random() {
    USERNAME="prx$(tr -dc 'a-z0-9' < /dev/urandom | head -c 8)"
    PASSWORD=$(tr -dc 'A-Za-z0-9!@#$%^&*' < /dev/urandom | head -c 20)
}

check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}[!] Please run as root: sudo $0${NC}"
        exit 1
    fi
}

#=============================================================================
# CORE FUNCTIONS
#=============================================================================

install_deps() {
    echo -e "${YELLOW}[*] Installing dependencies...${NC}"
    apt-get update -qq 2>/dev/null
    
    if ! command -v sshpass &> /dev/null; then
        apt-get install -y -qq sshpass 2>/dev/null
        echo -e "${GREEN}  ✓ sshpass installed${NC}"
    fi
    
    if ! command -v curl &> /dev/null; then
        apt-get install -y -qq curl 2>/dev/null
        echo -e "${GREEN}  ✓ curl installed${NC}"
    fi
}

fix_network() {
    echo -e "${YELLOW}[*] Configuring network...${NC}"
    
    # IPv4 precedence
    if ! grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
        echo -e "${GREEN}  ✓ IPv4 priority set${NC}"
    fi
    
    # SSH listen on IPv4 only
    sed -i 's/^#AddressFamily.*/AddressFamily inet/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^AddressFamily any/AddressFamily inet/' /etc/ssh/sshd_config 2>/dev/null
    if ! grep -q "^AddressFamily inet" /etc/ssh/sshd_config; then
        echo "AddressFamily inet" >> /etc/ssh/sshd_config
    fi
    
    # Enable TCP forwarding
    sed -i 's/^#AllowTcpForwarding.*/AllowTcpForwarding yes/' /etc/ssh/sshd_config 2>/dev/null
    sed -i 's/^AllowTcpForwarding no/AllowTcpForwarding yes/' /etc/ssh/sshd_config 2>/dev/null
    
    # ICMP (ping)
    iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null || true
    iptables -A OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT 2>/dev/null || true
    if command -v ufw &> /dev/null; then
        ufw allow proto icmp from any to any 2>/dev/null || true
    fi
    
    # Port for proxy
    if command -v ufw &> /dev/null; then
        ufw allow $PROXY_PORT/tcp 2>/dev/null || true
    fi
    iptables -A INPUT -p tcp --dport $PROXY_PORT -j ACCEPT 2>/dev/null || true
    
    # Enable forwarding
    sysctl -w net.ipv4.ip_forward=1 > /dev/null 2>&1
    
    systemctl restart sshd
    echo -e "${GREEN}  ✓ Network configured${NC}"
}

create_user() {
    echo -e "${YELLOW}[*] Creating proxy user...${NC}"
    gen_random
    
    # Remove existing user if any
    if id "$USERNAME" &>/dev/null; then
        userdel -r "$USERNAME" 2>/dev/null
    fi
    
    # Create user
    useradd -m -s /bin/bash "$USERNAME"
    echo "$USERNAME:$PASSWORD" | chpasswd
    
    # Setup SSH directory
    mkdir -p "/home/$USERNAME/.ssh"
    chmod 700 "/home/$USERNAME/.ssh"
    chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
    
    # Save config
    echo "USERNAME=$USERNAME" > "$CONFIG_FILE"
    echo "PASSWORD=$PASSWORD" >> "$CONFIG_FILE"
    echo "PORT=$PROXY_PORT" >> "$CONFIG_FILE"
    
    echo -e "${GREEN}  ✓ User created: $USERNAME${NC}"
}

start_tunnel() {
    echo -e "${YELLOW}[*] Starting SOCKS5 tunnel...${NC}"
    
    # Load credentials
    source "$CONFIG_FILE"
    
    # Kill existing tunnels on this port
    pkill -f "ssh.*-D.*$PORT" 2>/dev/null || true
    sleep 1
    
    # Start tunnel with sshpass
    sshpass -p "$PASSWORD" ssh -f -N \
        -D "0.0.0.0:$PORT" \
        -o "AddressFamily inet" \
        -o "StrictHostKeyChecking=no" \
        -o "UserKnownHostsFile=/dev/null" \
        -o "ServerAliveInterval=30" \
        -o "ServerAliveCountMax=3" \
        -o "TCPKeepAlive=yes" \
        "$USERNAME@127.0.0.1" 2>/dev/null
    
    sleep 2
    
    # Verify tunnel
    if pgrep -f "ssh.*-D.*$PORT" > /dev/null; then
        SERVER_IP=$(get_public_ip)
        
        # Save credentials file
        cat > "$CRED_FILE" << EOF
========================================
 SSH SOCKS5 Proxy Credentials
========================================
 Type:     SOCKS5
 Host:     $SERVER_IP
 Port:     $PORT
 Username: $USERNAME
 Password: $PASSWORD
========================================
 Test:     curl --socks5 $USERNAME:$PASSWORD@$SERVER_IP:$PORT ifconfig.me
========================================
EOF
        
        # Display success
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║              PROXY IS RUNNING ✓                      ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${YELLOW}Type:${NC}     ${GREEN}SOCKS5${NC}"
        echo -e "  ${YELLOW}Host:${NC}     ${GREEN}$SERVER_IP${NC}"
        echo -e "  ${YELLOW}Port:${NC}     ${GREEN}$PORT${NC}"
        echo -e "  ${YELLOW}Username:${NC} ${GREEN}$USERNAME${NC}"
        echo -e "  ${YELLOW}Password:${NC} ${GREEN}$PASSWORD${NC}"
        echo ""
        echo -e "  ${CYAN}Test command:${NC}"
        echo -e "  curl --socks5 $USERNAME:$PASSWORD@$SERVER_IP:$PORT ifconfig.me"
        echo ""
        echo -e "  ${CYAN}Credentials saved:${NC} $CRED_FILE"
        echo ""
        
        return 0
    else
        echo -e "${RED}[!] Failed to start tunnel${NC}"
        echo -e "${RED}    Debug: sshpass -p 'PASSWORD' ssh -v $USERNAME@127.0.0.1${NC}"
        return 1
    fi
}

show_status() {
    if pgrep -f "ssh.*-D.*$PROXY_PORT" > /dev/null; then
        echo -e "${GREEN}[✓] Proxy is running on port $PROXY_PORT${NC}"
        if [[ -f "$CRED_FILE" ]]; then
            cat "$CRED_FILE"
        fi
    else
        echo -e "${RED}[✗] Proxy is not running${NC}"
    fi
}

stop_proxy() {
    echo -e "${YELLOW}[*] Stopping proxy...${NC}"
    pkill -f "ssh.*-D.*$PROXY_PORT" 2>/dev/null || true
    echo -e "${GREEN}[✓] Proxy stopped${NC}"
}

#=============================================================================
# MAIN
#=============================================================================

check_root

case "${1}" in
    install|setup|start)
        banner
        install_deps
        fix_network
        create_user
        start_tunnel
        ;;
    stop)
        stop_proxy
        ;;
    status|info)
        show_status
        ;;
    restart)
        stop_proxy
        sleep 2
        banner
        start_tunnel
        ;;
    user|newuser)
        create_user
        echo -e "${YELLOW}Run '$0 start' to start proxy with new user${NC}"
        ;;
    *)
        echo "Usage: $0 {install|stop|status|restart|user}"
        echo ""
        echo "  install   - Full setup (deps + network + user + start)"
        echo "  stop      - Stop proxy tunnel"
        echo "  status    - Show proxy status and credentials"
        echo "  restart   - Restart proxy tunnel"
        echo "  user      - Create new random user only"
        exit 1
        ;;
esac
