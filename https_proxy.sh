#!/bin/bash
# HTTPS → HTTP 反代一键脚本（免停机 + 自定义端口 + 自动续期）
# 系统支持: Debian/Ubuntu/CentOS

if [ "$(id -u)" != "0" ]; then
    echo "请用 root 用户运行此脚本"
    exit 1
fi

read -p "请输入你的域名: " DOMAIN
read -p "请输入HTTP目标IP: " TARGET_IP
read -p "请输入HTTP目标端口: " TARGET_PORT
read -p "请输入HTTPS监听端口(默认443): " HTTPS_PORT
HTTPS_PORT=${HTTPS_PORT:-443}

echo ">>> 安装 Nginx 和 acme.sh ..."
apt update -y && apt install -y nginx socat curl cron || yum install -y epel-release nginx socat curl cronie
curl https://get.acme.sh | sh
source ~/.bashrc

# 创建目录
mkdir -p /etc/nginx/ssl
mkdir -p /var/www/acme

# 临时HTTP配置（证书申请用）
cat > /etc/nginx/conf.d/${DOMAIN}_temp.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }
}
EOF

# 启动Nginx
systemctl enable nginx
systemctl reload nginx || systemctl start nginx

# 申请证书（webroot模式）
~/.acme.sh/acme.sh --issue -d $DOMAIN --webroot /var/www/acme --force --server letsencrypt
~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
--key-file       /etc/nginx/ssl/$DOMAIN.key \
--fullchain-file /etc/nginx/ssl/$DOMAIN.crt \
--reloadcmd     "systemctl reload nginx"

# 删除临时配置
rm -f /etc/nginx/conf.d/${DOMAIN}_temp.conf

# 正式反代配置
cat > /etc/nginx/conf.d/$DOMAIN.conf <<EOF
server {
    listen ${HTTPS_PORT} ssl;
    server_name $DOMAIN;

    ssl_certificate /etc/nginx/ssl/$DOMAIN.crt;
    ssl_certificate_key /etc/nginx/ssl/$DOMAIN.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://$TARGET_IP:$TARGET_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host:${HTTPS_PORT}\$request_uri;
}
EOF

# 重载Nginx
systemctl reload nginx

# 设置自动续期（acme.sh自带）
~/.acme.sh/acme.sh --upgrade --auto-upgrade

# 确保cron服务开启
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null
    systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null
else
    service cron start 2>/dev/null || service crond start 2>/dev/null
fi

echo "======================================"
echo "HTTPS反代部署完成！"
echo "访问: https://$DOMAIN:$HTTPS_PORT"
echo "反代目标: http://$TARGET_IP:$TARGET_PORT"
echo "证书路径: /etc/nginx/ssl/$DOMAIN.crt"
echo "证书自动续期: 已启用 (acme.sh)"
echo "======================================"
