#!/bin/bash
# ====================================================
# 一键 Nginx HTTPS 反代 + 多种证书申请 + 自动续期脚本
# 支持：webroot、standalone、dns 手动、Cloudflare DNS API
# 支持自定义 HTTPS 端口、免停机申请、自动续期
# 作者：ChatGPT
# ====================================================

set -e

# 检查 root 权限
if [ "$(id -u)" != "0" ]; then
    echo "请用 root 用户执行此脚本"
    exit 1
fi

# 读取输入参数
read -p "请输入你的域名 (多个域名用空格隔开): " DOMAIN_INPUT
read -p "请输入 HTTP 目标 IP: " TARGET_IP
read -p "请输入 HTTP 目标端口: " TARGET_PORT
read -p "请输入 HTTPS 监听端口 (默认443): " HTTPS_PORT
HTTPS_PORT=${HTTPS_PORT:-443}

# 安装必要软件
echo "[INFO] 安装 Nginx、curl、socat、cron ..."
if command -v apt >/dev/null; then
    apt update -y
    apt install -y nginx curl socat cron
elif command -v yum >/dev/null; then
    yum install -y epel-release
    yum install -y nginx curl socat cronie
else
    echo "未知 Linux 发行版，请手动安装 nginx curl socat cron"
    exit 1
fi

# 安装 acme.sh
if ! command -v acme.sh >/dev/null 2>&1; then
    echo "[INFO] 安装 acme.sh ..."
    curl https://get.acme.sh | sh
fi
source ~/.bashrc

# 证书存放目录
CERT_DIR="/etc/nginx/ssl"
mkdir -p "$CERT_DIR"

# 选择证书申请方式
echo ""
echo "选择证书申请方式："
echo "1) webroot (免停机，80端口需可用)"
echo "2) standalone (临时占用80端口，适合无Nginx运行时)"
echo "3) dns 手动验证 (需自行添加 TXT 记录)"
echo "4) Cloudflare DNS API (自动添加 TXT 记录，需 API Token)"
read -p "请输入选项 [1-4]: " CERT_MODE

# 解析第一个域名（默认主域名）
MAIN_DOMAIN=$(echo $DOMAIN_INPUT | awk '{print $1}')

# 申请证书函数
issue_cert() {
    case $CERT_MODE in
        1)
            echo "[INFO] 选择 webroot 模式"
            WEBROOT_DIR="/var/www/acme"
            mkdir -p "$WEBROOT_DIR"

            # 临时配置，方便验证
            cat > /etc/nginx/conf.d/${MAIN_DOMAIN}_temp.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN_INPUT;
    location /.well-known/acme-challenge/ {
        root $WEBROOT_DIR;
    }
}
EOF

            systemctl reload nginx || systemctl start nginx

            ~/.acme.sh/acme.sh --issue -d $DOMAIN_INPUT --webroot "$WEBROOT_DIR" --force --server letsencrypt
            ;;
        2)
            echo "[INFO] 选择 standalone 模式"
            systemctl stop nginx
            ~/.acme.sh/acme.sh --issue -d $DOMAIN_INPUT --standalone --force --server letsencrypt
            systemctl start nginx
            ;;
        3)
            echo "[INFO] 选择 DNS 手动验证模式"
            echo "请根据提示添加 TXT 记录"
            ~/.acme.sh/acme.sh --issue -d $DOMAIN_INPUT --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please --force --server letsencrypt
            ;;
        4)
            echo "[INFO] 选择 Cloudflare DNS API 模式"
            read -p "请输入 Cloudflare API Token (需 Zone:Read 和 DNS:Edit 权限): " CF_TOKEN
            export CF_Token="$CF_TOKEN"
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d $DOMAIN_INPUT --force --server letsencrypt
            ;;
        *)
            echo "无效选项"
            exit 1
            ;;
    esac
}

# 安装证书函数
install_cert() {
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN_INPUT \
      --key-file       $CERT_DIR/$MAIN_DOMAIN.key \
      --fullchain-file $CERT_DIR/$MAIN_DOMAIN.crt \
      --reloadcmd     "systemctl reload nginx"
}

# 申请证书
issue_cert

# 删除临时验证配置（如果有）
rm -f /etc/nginx/conf.d/${MAIN_DOMAIN}_temp.conf

# 写入 Nginx 反代配置
cat > /etc/nginx/conf.d/$MAIN_DOMAIN.conf <<EOF
server {
    listen $HTTPS_PORT ssl;
    server_name $DOMAIN_INPUT;

    ssl_certificate $CERT_DIR/$MAIN_DOMAIN.crt;
    ssl_certificate_key $CERT_DIR/$MAIN_DOMAIN.key;
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
    server_name $DOMAIN_INPUT;
    return 301 https://\$host:$HTTPS_PORT\$request_uri;
}
EOF

# 安装证书
install_cert

# 启用 nginx 开机启动及启动服务
systemctl enable nginx
systemctl restart nginx

# 设置自动续期和自动升级 acme.sh
~/.acme.sh/acme.sh --upgrade --auto-upgrade

# 确保 cron 服务开启
if command -v systemctl >/dev/null 2>&1; then
    systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null
    systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null
else
    service cron start 2>/dev/null || service crond start 2>/dev/null
fi

echo "=========================================="
echo "HTTPS反代配置完成！"
echo "访问地址：https://$MAIN_DOMAIN:$HTTPS_PORT"
echo "反代目标：http://$TARGET_IP:$TARGET_PORT"
echo "证书路径：$CERT_DIR"
echo "证书申请方式：$CERT_MODE"
echo "自动续期已启用"
echo "=========================================="
