#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function: Show Header
show_header() {
    clear
    echo -e "${CYAN}==========================================================${NC}"
    echo -e "${CYAN}           DoH Gateway & SmartDNS Auto Installer          ${NC}"
    echo -e "${YELLOW}        YouTube Channel: https://www.youtube.com/@iAghapour ${NC}"
    echo -e "${CYAN}==========================================================${NC}"
    echo ""
}

# Function: View Logs
view_logs() {
    while true; do
        show_header
        echo -e "${GREEN}>>> Log Viewer Menu${NC}"
        echo -e "1) ${YELLOW}SmartDNS Logs${NC} (Check DNS queries)"
        echo -e "2) ${YELLOW}Nginx Access Logs${NC} (Check connections)"
        echo -e "3) ${YELLOW}Nginx Error Logs${NC} (Check errors)"
        echo -e "0) ${RED}Back to Main Menu${NC}"
        echo ""
        echo -e "${CYAN}Note: Press Ctrl+C to exit logs.${NC}"
        
        trap - SIGINT
        read -p "Select a log to view: " log_choice
        case $log_choice in
            1)
                echo -e "${GREEN}Showing SmartDNS logs...${NC}"
                tail -f /var/log/smartdns/smartdns.log
                ;;
            2)
                echo -e "${GREEN}Showing Nginx Access logs...${NC}"
                tail -f /var/log/nginx/doh-access.log
                ;;
            3)
                echo -e "${GREEN}Showing Nginx Error logs...${NC}"
                tail -f /var/log/nginx/doh-error.log
                ;;
            0)
                trap '' SIGINT
                return
                ;;
            *)
                echo -e "${RED}Invalid option!${NC}"
                sleep 1
                ;;
        esac
        trap '' SIGINT
    done
}

# Function: Install
install_panel() {
    show_header
    echo -e "${GREEN}>>> Starting Installation Process...${NC}"
    
    # 0. Ensure Internet works for downloads
    echo "nameserver 8.8.8.8" > /etc/resolv.conf

    # 1. Ask for Domain
    echo -e "${YELLOW}Please enter your domain (without http/https)${NC}"
    read -p "Example (sub.domain.com): " DOMAIN

    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}No domain entered. Returning to menu...${NC}"
        sleep 2
        return
    fi

    # 2. Install Dependencies
    echo -e "${GREEN}>>> Installing Dependencies...${NC}"
    apt update
    apt install curl socat nginx tar -y

    # 3. Get SSL (Acme.sh)
    echo -e "${GREEN}>>> Obtaining SSL Certificate...${NC}"
    
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        curl https://get.acme.sh | sh
    fi
    
    systemctl stop nginx

    # Issue Cert
    /root/.acme.sh/acme.sh --register-account -m "admin@$DOMAIN" --server zerossl
    /root/.acme.sh/acme.sh --issue -d "$DOMAIN" --standalone --force
    
    if [ ! -f "/root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.cer" ]; then
        echo -e "${RED}Error: SSL Certificate creation failed.${NC}"
        read -p "Press Enter to return..."
        return
    fi

    mkdir -p /etc/nginx/ssl
    /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --ecc \
        --fullchain-file /etc/nginx/ssl/fullchain.pem \
        --key-file /etc/nginx/ssl/privkey.pem
    
    chmod 644 /etc/nginx/ssl/fullchain.pem
    chmod 600 /etc/nginx/ssl/privkey.pem

    # 4. Download SmartDNS
    echo -e "${GREEN}>>> Downloading SmartDNS...${NC}"
    
    rm -rf smartdns*
    wget -O smartdns.tar.gz https://github.com/pymumu/smartdns/releases/download/Release47.1/smartdns.1.2025.11.09-1443.x86_64-linux-all.tar.gz

    tar zxvf smartdns.tar.gz
    cd smartdns
    ./install -i
    cd ..
    rm -rf smartdns*

    # 5. Disable System DNS (Critical Step)
    echo -e "${GREEN}>>> Freeing Port 53...${NC}"
    
    systemctl stop systemd-resolved
    systemctl disable systemd-resolved
    rm -f /etc/resolv.conf
    
    # 6. Configure SmartDNS
    echo -e "${GREEN}>>> Configuring SmartDNS...${NC}"
    mkdir -p /etc/smartdns
    
    cat > /etc/smartdns/smartdns.conf <<EOF_SMART
bind [::]:53
cache-size 4096
prefetch-domain yes
serve-expired yes
log-level info
log-file /var/log/smartdns/smartdns.log
server 8.8.8.8
server 1.1.1.1
force-AAAA-SOA yes
EOF_SMART

    # Set Localhost as DNS
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
    
    systemctl restart smartdns
    sleep 2
    
    if systemctl is-active --quiet smartdns; then
        echo -e "${GREEN}SmartDNS is running on Port 53.${NC}"
    else
        echo -e "${RED}Warning: SmartDNS failed to start! Check logs.${NC}"
    fi

    # 7. Nginx Config
    echo -e "${GREEN}>>> Configuring Nginx...${NC}"
    
    cat > /etc/nginx/sites-available/doh <<EOF_NGINX
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    
    server_name ${DOMAIN};

    ssl_certificate /etc/nginx/ssl/fullchain.pem;
    ssl_certificate_key /etc/nginx/ssl/privkey.pem;
    
    ssl_protocols TLSv1.2 TLSv1.3;
    
    access_log /var/log/nginx/doh-access.log;
    error_log /var/log/nginx/doh-error.log;

    location /dns-query {
        proxy_pass https://1.1.1.1/dns-query;
        
        proxy_set_header Host cloudflare-dns.com;
        proxy_ssl_name cloudflare-dns.com;
        proxy_ssl_server_name on;
        
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
    
    location / {
        add_header Content-Type text/plain;
        return 200 "DoH Server is Ready!\nYour IP: \$remote_addr";
    }
}
EOF_NGINX

    ln -s /etc/nginx/sites-available/doh /etc/nginx/sites-enabled/ 2>/dev/null
    rm /etc/nginx/sites-enabled/default 2>/dev/null

    nginx -t
    systemctl restart nginx

    echo -e "${GREEN}=========================================${NC}"
    echo -e "${GREEN}   Installation Completed!  ${NC}"
    echo -e "${YELLOW}   Your DoH URL: https://${DOMAIN}/dns-query   ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "${RED}IMPORTANT TIPS:${NC}"
    echo -e "1. ${YELLOW}SSL/TLS:${NC} Make sure it is set to ${GREEN}Full (Strict)${NC} in Cloudflare."
    echo -e "2. ${YELLOW}Proxy Mode:${NC} If you face connection issues, try turning ${GREEN}ON${NC} the Cloudflare Proxy (Orange Cloud)."
    echo -e "${GREEN}=========================================${NC}"
    read -p "Press Enter to return..."
}

# Function: Uninstall
uninstall_panel() {
    show_header
    echo -e "${RED}!!! WARNING: This will remove all configurations !!!${NC}"
    read -p "Are you sure? (y/n): " confirm
    if [[ "$confirm" != "y" ]]; then return; fi

    echo -e "${YELLOW}>>> Removing services...${NC}"
    systemctl stop nginx smartdns
    
    rm -rf /etc/smartdns
    systemctl disable smartdns
    
    rm /etc/nginx/sites-enabled/doh /etc/nginx/sites-available/doh
    rm -rf /etc/nginx/ssl
    
    echo -e "${YELLOW}>>> Restoring system DNS...${NC}"
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    systemctl enable systemd-resolved
    systemctl start systemd-resolved

    echo -e "${GREEN}Done.${NC}"
    read -p "Press Enter..."
}

# Main Menu
trap '' SIGINT

while true; do
    show_header
    echo -e "1) ${GREEN}Install & Setup${NC}"
    echo -e "2) ${RED}Uninstall${NC}"
    echo -e "3) ${YELLOW}View Logs${NC}"
    echo -e "0) ${YELLOW}Exit${NC}"
    read -p "Select: " choice

    case $choice in
        1) install_panel ;;
        2) uninstall_panel ;;
        3) view_logs ;;
        0) exit 0 ;;
        *) echo "Invalid" ; sleep 1 ;;
    esac
done
