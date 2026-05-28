#!/bin/bash

#=============================================================================
# SSH SOCKS5 Proxy Manager - Final Fixed Version
# Fixes: Auto-login with password, shows credentials clearly
#=============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
CONFIG_DIR="$HOME/.ssh_proxy"
CONFIG_FILE="$CONFIG_DIR/config"
CRED_FILE="$CONFIG_DIR/credentials.txt"

mkdir -p "$CONFIG_DIR"

print_banner() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     SSH SOCKS5 Proxy Manager v2.1         ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
}

# تولید یوزرنیم و پسورد رندوم
generate_random_credentials() {
    RANDOM_USER="prx$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)"
    RANDOM_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*' | fold -w 16 | head -n 1)
}

# نصب sshpass اگر نیست
install_sshpass() {
    if ! command -v sshpass &> /dev/null; then
        echo -e "${YELLOW}[*] Installing sshpass...${NC}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq sshpass
        echo -e "${GREEN}[✓] sshpass installed${NC}"
    fi
}

# رفع مشکلات شبکه
fix_network() {
    echo -e "${YELLOW}[*] Fixing IPv4 priority...${NC}"
    
    # اولویت IPv4
    if ! grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" | sudo tee -a /etc/gai.conf > /dev/null
    fi
    
    # SSH فقط IPv4
    sudo sed -i 's/#AddressFamily any/AddressFamily inet/' /etc/ssh/sshd_config 2>/dev/null
    sudo sed -i 's/AddressFamily any/AddressFamily inet/' /etc/ssh/sshd_config 2>/dev/null
    if ! grep -q "AddressFamily inet" /etc/ssh/sshd_config; then
        echo "AddressFamily inet" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi
    
    # TCP Forwarding
    sudo sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/' /etc/ssh/sshd_config 2>/dev/null
    sudo sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/' /etc/ssh/sshd_config 2>/dev/null
    
    # فعال‌سازی ICMP (پینگ)
    if command -v ufw &> /dev/null; then
        sudo ufw allow proto icmp from any to any 2>/dev/null
    fi
    sudo iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null
    sudo iptables -A OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT 2>/dev/null
    
    # IP forwarding
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
    
    # ریست سرویس
    sudo systemctl restart sshd
    echo -e "${GREEN}[✓] Network optimized${NC}"
}

# ساخت کاربر پروکسی
create_user() {
    print_banner
    generate_random_credentials
    
    echo -e "${YELLOW}[*] Creating proxy user...${NC}"
    
    # حذف کاربر قبلی اگر هست
    if id "$RANDOM_USER" &>/dev/null; then
        sudo userdel -r "$RANDOM_USER" 2>/dev/null
    fi
    
    # ساخت کاربر
    sudo useradd -m -s /bin/bash "$RANDOM_USER"
    echo "$RANDOM_USER:$RANDOM_PASS" | sudo chpasswd
    
    # تنظیم SSH
    sudo mkdir -p "/home/$RANDOM_USER/.ssh"
    sudo chmod 700 "/home/$RANDOM_USER/.ssh"
    sudo chown -R "$RANDOM_USER:$RANDOM_USER" "/home/$RANDOM_USER"
    
    # ذخیره اطلاعات
    echo "USER=$RANDOM_USER" > "$CONFIG_FILE"
    echo "PASS=$RANDOM_PASS" >> "$CONFIG_FILE"
    
    # ذخیره در فایل مجزا برای نمایش
    cat > "$CRED_FILE" << EOF
=================================
SSH SOCKS5 Proxy Credentials
=================================
Username: $RANDOM_USER
Password: $RANDOM_PASS
Server:   \$(curl -4 -s ifconfig.me)
Port:     1080
=================================
EOF
    
    echo -e "${GREEN}[✓] User created:${NC}"
    echo -e "    Username: ${YELLOW}$RANDOM_USER${NC}"
    echo -e "    Password: ${YELLOW}$RANDOM_PASS${NC}"
}

# شروع پروکسی با sshpass
start_proxy() {
    install_sshpass
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        create_user
    fi
    
    source "$CONFIG_FILE"
    print_banner
    
    SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com || hostname -I | awk '{print $1}')
    
    # کشتن پروکسی‌های قبلی
    pkill -f "ssh.*-D.*1080" 2>/dev/null
    
    echo -e "${YELLOW}[*] Starting proxy tunnel...${NC}"
    
    # استفاده از sshpass برای ورود خودکار
    sshpass -p "$PASS" ssh -f -N -D "0.0.0.0:1080" \
        -o "AddressFamily inet" \
        -o "ServerAliveInterval 30" \
        -o "ServerAliveCountMax 3" \
        -o "StrictHostKeyChecking=no" \
        -o "UserKnownHostsFile=/dev/null" \
        "$USER@127.0.0.1" 2>/dev/null
    
    if pgrep -f "ssh.*-D.*1080" > /dev/null; then
        echo ""
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}              PROXY IS RUNNING!                       ${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
        echo ""
        echo -e "  ${YELLOW}Type:${NC}     SOCKS5"
        echo -e "  ${YELLOW}Host:${NC}     ${GREEN}$SERVER_IP${NC}"
        echo -e "  ${YELLOW}Port:${NC}     ${GREEN}1080${NC}"
        echo -e "  ${YELLOW}Username:${NC} ${GREEN}$USER${NC}"
        echo -e "  ${YELLOW}Password:${NC} ${GREEN}$PASS${NC}"
        echo ""
        echo -e "  ${BLUE}Test:${NC} curl --socks5 $USER:$PASS@$SERVER_IP:1080 ifconfig.me"
        echo ""
        echo -e "  ${YELLOW}Credentials saved: $CRED_FILE${NC}"
        echo -e "${GREEN}══════════════════════════════════════════════════════${NC}"
    else
        echo -e "${RED}[!] Failed to start proxy. Check credentials.${NC}"
        echo -e "${RED}    Try running: ssh $USER@127.0.0.1${NC}"
    fi
}

# نمایش اطلاعات
show_info() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        SERVER_IP=$(curl -4 -s ifconfig.me 2>/dev/null)
        echo -e "${GREEN}Proxy Credentials:${NC}"
        echo -e "  User: $USER"
        echo -e "  Pass: $PASS"
        echo -e "  Host: $SERVER_IP:1080"
    else
        echo -e "${RED}No proxy configured yet.${NC}"
    fi
}

# منوی اصلی
case "${1:-start}" in
    "fix")
        fix_network
        ;;
    "user")
        create_user
        ;;
    "info")
        show_info
        ;;
    "stop")
        pkill -f "ssh.*-D.*1080"
        echo -e "${GREEN}[✓] Proxy stopped${NC}"
        ;;
    *)
        fix_network
        start_proxy
        ;;
esac
