#!/bin/bash

#=============================================================================
# SSH SOCKS5 Proxy Manager - Enhanced Version
# Fixes: IPv6 priority, ICMP ping blocking, Random user/pass generation
#=============================================================================

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
CONFIG_FILE="$HOME/.ssh_proxy_config"

print_banner() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║     SSH SOCKS5 Proxy Manager v2.0         ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}"
}

# تولید یوزرنیم و پسورد رندوم
generate_random_credentials() {
    # یوزرنیم: ۸ کاراکتر حروف کوچک و اعداد
    RANDOM_USER="prx$(cat /dev/urandom | tr -dc 'a-z0-9' | fold -w 6 | head -n 1)"
    # پسورد: ۱۶ کاراکتر امن
    RANDOM_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9!@#$%^&*' | fold -w 16 | head -n 1)
}

# رفع مشکل IPv6 و پینگ
fix_network_issues() {
    print_banner
    echo -e "${YELLOW}[*] Fixing network issues...${NC}"
    
    # ۱. تنظیم IPv4 به عنوان اولویت (رفع خروجی IPv6)
    echo -e "${BLUE}[*] Setting IPv4 priority...${NC}"
    
    # تغییر تنظیمات gai.conf برای اولویت دادن به IPv4
    if ! grep -q "precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
        echo "precedence ::ffff:0:0/96  100" | sudo tee -a /etc/gai.conf > /dev/null
        echo -e "${GREEN}[✓] IPv4 precedence set${NC}"
    fi
    
    # غیرفعال کردن IPv6 در SSH (رفع ارورهای اتصال)
    sudo sed -i 's/#AddressFamily any/AddressFamily inet/' /etc/ssh/sshd_config
    sudo sed -i 's/AddressFamily any/AddressFamily inet/' /etc/ssh/sshd_config
    if ! grep -q "AddressFamily inet" /etc/ssh/sshd_config; then
        echo "AddressFamily inet" | sudo tee -a /etc/ssh/sshd_config > /dev/null
    fi
    
    # ۲. فعال کردن ICMP (پینگ) - اگر فایروال داره بلاک می‌کنه
    echo -e "${BLUE}[*] Enabling ICMP (ping)...${NC}"
    # برای UFW
    if command -v ufw &> /dev/null; then
        sudo ufw allow proto icmp from any to any 2>/dev/null
        echo -e "${GREEN}[✓] ICMP allowed in UFW${NC}"
    fi
    # برای iptables
    sudo iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT 2>/dev/null
    sudo iptables -A OUTPUT -p icmp --icmp-type echo-reply -j ACCEPT 2>/dev/null
    # ذخیره قوانین iptables
    if command -v netfilter-persistent &> /dev/null; then
        sudo netfilter-persistent save 2>/dev/null
    elif command -v iptables-save &> /dev/null; then
        sudo iptables-save > /etc/iptables/rules.v4 2>/dev/null
    fi
    
    # فعال‌سازی packet forwarding (برای عملکرد بهتر پروکسی)
    sudo sysctl -w net.ipv4.ip_forward=1 > /dev/null
    if ! grep -q "net.ipv4.ip_forward = 1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
    
    # ریست سرویس SSH
    sudo systemctl restart sshd
    echo -e "${GREEN}[✓] SSH service restarted${NC}"
}

# ساخت کاربر پروکسی با یوزر/پسورد رندوم
create_proxy_user() {
    print_banner
    echo -e "${BLUE}[+] Creating Proxy User (Random Credentials)${NC}"
    
    generate_random_credentials
    
    echo -e "${YELLOW}[*] Generated Credentials:${NC}"
    echo -e "    Username: ${GREEN}$RANDOM_USER${NC}"
    echo -e "    Password: ${GREEN}$RANDOM_PASS${NC}"
    echo ""
    
    # ذخیره اطلاعات در فایل امن
    echo "USER=$RANDOM_USER" > "$CONFIG_FILE"
    echo "PASS=$RANDOM_PASS" >> "$CONFIG_FILE"
    
    # ساخت یوزر با shell محدود
    sudo useradd -m -s /bin/false "$RANDOM_USER" 2>/dev/null
    echo "$RANDOM_USER:$RANDOM_PASS" | sudo chpasswd
    
    # ست کردن SSH key (اختیاری)
    sudo mkdir -p "/home/$RANDOM_USER/.ssh"
    sudo chmod 700 "/home/$RANDOM_USER/.ssh"
    sudo chown -R "$RANDOM_USER:$RANDOM_USER" "/home/$RANDOM_USER"
    
    echo -e "${GREEN}[✓] User created and restricted to proxy only${NC}"
    echo ""
    echo -e "${YELLOW}Important: Save these credentials!${NC}"
    echo -e "Username: ${GREEN}$RANDOM_USER${NC}"
    echo -e "Password: ${GREEN}$RANDOM_PASS${NC}"
}

# شروع پروکسی (حل مشکل IPv6)
start_proxy() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}[!] No user found. Creating one first...${NC}"
        create_proxy_user
    fi
    
    source "$CONFIG_FILE"
    print_banner
    
    # دریافت IPv4 عمومی (مطمئن می‌شیم IPv4 برگرده نه IPv6)
    SERVER_IP=$(curl -4 -s ifconfig.me 2>/dev/null || curl -4 -s icanhazip.com 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')
    
    echo -e "${GREEN}[✓] Starting SOCKS5 Proxy${NC}"
    echo -e "    Server IPv4: ${YELLOW}$SERVER_IP${NC}"
    echo -e "    Port: ${YELLOW}1080${NC}"
    echo -e "    User: ${YELLOW}$USER${NC}"
    
    # فعال‌سازی TCP Forwarding
    sudo sed -i 's/#AllowTcpForwarding yes/AllowTcpForwarding yes/' /etc/ssh/sshd_config
    sudo sed -i 's/AllowTcpForwarding no/AllowTcpForwarding yes/' /etc/ssh/sshd_config
    sudo systemctl restart sshd
    
    # راه‌اندازی تونل با SSH، مجبور به استفاده از IPv4
    ssh -f -N -D "0.0.0.0:1080" \
        -o "AddressFamily inet" \
        -o "ServerAliveInterval 30" \
        -o "ServerAliveCountMax 3" \
        -o "StrictHostKeyChecking=no" \
        "$USER@127.0.0.1" \
        2>/dev/null
    
    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}═════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  Proxy Active!${NC}"
        echo -e "${GREEN}  SOCKS5 | $SERVER_IP:1080${NC}"
        echo -e "${GREEN}  User: $USER | Pass: $PASS${NC}"
        echo -e "${GREEN}═════════════════════════════════════════════${NC}"
    else
        echo -e "${RED}[!] Failed to start proxy${NC}"
    fi
}

# اجرای اصلی
case "$1" in
    "fix")
        fix_network_issues
        ;;
    "setup")
        create_proxy_user
        ;;
    "start")
        start_proxy
        ;;
    *)
        fix_network_issues
        create_proxy_user
        start_proxy
        echo ""
        echo -e "${BLUE}Usage: $0 {fix|setup|start}${NC}"
        ;;
esac
