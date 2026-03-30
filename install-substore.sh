#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
print_success() { echo -e "${GREEN}[OK]${NC} $*"; }
print_warning() { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error()   { echo -e "${RED}[ERR]${NC} $*"; }

trap 'print_error "脚本执行失败，出错行号: $LINENO"' ERR

if [[ "${EUID}" -ne 0 ]]; then
  print_error "请使用 root 运行此脚本"
  exit 1
fi

if [[ ! -f /etc/debian_version ]]; then
  print_error "当前脚本仅支持 Debian / Ubuntu 系"
  exit 1
fi

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

generate_api_path() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]
}

port_in_use() {
  local port="$1"
  ss -ltn "( sport = :${port} )" | tail -n +2 | grep -q .
}

get_public_ip() {
  local ip=""
  if command_exists curl; then
    ip="$(curl -4 -fsSL --max-time 5 https://api.ipify.org || true)"
  fi
  echo "$ip"
}

backup_file_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    cp -a "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
  fi
}

print_info "==============================================="
print_info "        Sub-Store Docker + Nginx 部署"
print_info "==============================================="
echo

read -rp "请输入域名: " DOMAIN
if [[ -z "${DOMAIN}" ]] || ! validate_domain "${DOMAIN}"; then
  print_error "域名格式无效"
  exit 1
fi

read -rp "请输入宿主机本地监听端口（默认 4837）: " HOST_PORT
HOST_PORT="${HOST_PORT:-4837}"

if ! [[ "${HOST_PORT}" =~ ^[0-9]+$ ]] || (( HOST_PORT < 1 || HOST_PORT > 65535 )); then
  print_error "端口无效"
  exit 1
fi

CONTAINER_PORT=3001

read -rp "请输入 API 路径（留空自动生成，例如 /api-xxxxx）: " API_PATH
if [[ -z "${API_PATH}" ]]; then
  API_PATH="/api-$(generate_api_path)"
fi
[[ "${API_PATH}" =~ ^/ ]] || API_PATH="/${API_PATH}"

read -rp "是否现在申请 SSL 证书？(y/N): " ENABLE_SSL
ENABLE_SSL="${ENABLE_SSL:-N}"

read -rp "是否启用自动更新容器脚本（默认不启用定时任务）？(y/N): " ENABLE_AUTO_UPDATE
ENABLE_AUTO_UPDATE="${ENABLE_AUTO_UPDATE:-N}"

DATA_DIR="/opt/sub-store-data"
APP_DIR="/opt/sub-store"
RUN_SCRIPT="${APP_DIR}/run_substore.sh"
UPDATE_SCRIPT="${APP_DIR}/update_substore.sh"
ENV_FILE="${APP_DIR}/substore.env"
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"
NGINX_LINK="/etc/nginx/sites-enabled/${DOMAIN}.conf"

API_URL="https://${DOMAIN}${API_PATH}"

echo
print_info "部署配置确认："
echo "域名: ${DOMAIN}"
echo "本地监听地址: 127.0.0.1:${HOST_PORT}"
echo "容器内部端口: ${CONTAINER_PORT}"
echo "API 路径: ${API_PATH}"
echo "API URL: ${API_URL}"
echo "数据目录: ${DATA_DIR}"
echo

read -rp "确认继续？(y/N): " CONFIRM
[[ "${CONFIRM}" =~ ^[Yy]$ ]] || exit 0

echo
print_info "1/8 安装基础依赖..."
apt update
apt install -y curl wget ca-certificates gnupg lsb-release nginx certbot python3-certbot-nginx docker.io

systemctl enable docker nginx
systemctl start docker nginx

print_success "基础依赖安装完成"

echo
print_info "2/8 检查端口占用..."
if port_in_use "${HOST_PORT}"; then
  print_error "宿主机端口 ${HOST_PORT} 已被占用，请换一个端口"
  ss -ltnp | grep ":${HOST_PORT} " || true
  exit 1
fi

if ! port_in_use 80; then
  print_info "80 端口当前空闲"
else
  print_warning "80 端口正在被某服务占用，这通常是 Nginx，属正常现象"
fi

echo
print_info "3/8 准备目录与环境文件..."
mkdir -p "${DATA_DIR}" "${APP_DIR}"

cat > "${ENV_FILE}" <<EOF
DOMAIN="${DOMAIN}"
HOST_PORT="${HOST_PORT}"
CONTAINER_PORT="${CONTAINER_PORT}"
API_PATH="${API_PATH}"
API_URL="${API_URL}"
DATA_DIR="${DATA_DIR}"
EOF

chmod 600 "${ENV_FILE}"

print_success "环境文件已写入: ${ENV_FILE}"

echo
print_info "4/8 拉取镜像并创建运行脚本..."
cat > "${RUN_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/sub-store/substore.env

docker pull xream/sub-store:latest

docker stop sub-store >/dev/null 2>&1 || true
docker rm sub-store >/dev/null 2>&1 || true

docker run -d \
  --name sub-store \
  --restart=always \
  -e "SUB_STORE_FRONTEND_BACKEND_PATH=${API_PATH}" \
  -e "API_URL=${API_URL}" \
  -p "127.0.0.1:${HOST_PORT}:${CONTAINER_PORT}" \
  -v "${DATA_DIR}:/opt/app/data" \
  xream/sub-store:latest
EOF
chmod +x "${RUN_SCRIPT}"

cat > "${UPDATE_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/sub-store/substore.env

echo "[INFO] Pulling latest image..."
docker pull xream/sub-store:latest

echo "[INFO] Recreating container..."
docker stop sub-store >/dev/null 2>&1 || true
docker rm sub-store >/dev/null 2>&1 || true

docker run -d \
  --name sub-store \
  --restart=always \
  -e "SUB_STORE_FRONTEND_BACKEND_PATH=${API_PATH}" \
  -e "API_URL=${API_URL}" \
  -p "127.0.0.1:${HOST_PORT}:${CONTAINER_PORT}" \
  -v "${DATA_DIR}:/opt/app/data" \
  xream/sub-store:latest

sleep 3

if docker ps --format '{{.Names}}' | grep -qx 'sub-store'; then
  echo "[OK] sub-store update success"
else
  echo "[ERR] sub-store failed after update"
  docker logs --tail 100 sub-store || true
  exit 1
fi
EOF
chmod +x "${UPDATE_SCRIPT}"

print_success "运行脚本已生成"

echo
print_info "5/8 启动 Sub-Store 容器..."
bash "${RUN_SCRIPT}"
sleep 3

if ! docker ps --format '{{.Names}}' | grep -qx 'sub-store'; then
  print_error "容器未成功启动"
  docker logs --tail 100 sub-store || true
  exit 1
fi

print_success "容器启动成功"

echo
print_info "6/8 写入 Nginx 配置..."
backup_file_if_exists "${NGINX_CONF}"

cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:${HOST_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    location /health {
        access_log off;
        add_header Content-Type text/plain;
        return 200 "healthy\n";
    }
}
EOF

ln -sfn "${NGINX_CONF}" "${NGINX_LINK}"

if [[ -f /etc/nginx/sites-enabled/default ]]; then
  backup_file_if_exists /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/sites-enabled/default
fi

nginx -t
systemctl reload nginx
print_success "Nginx HTTP 配置已生效"

echo
print_info "7/8 检查站点解析..."
PUBLIC_IP="$(get_public_ip)"
if [[ -n "${PUBLIC_IP}" ]]; then
  print_info "当前服务器公网 IPv4: ${PUBLIC_IP}"
else
  print_warning "未能自动获取公网 IP，请手动确认域名解析"
fi

if [[ "${ENABLE_SSL}" =~ ^[Yy]$ ]]; then
  echo
  print_info "开始申请 SSL 证书..."
  read -rp "请输入邮箱（可留空）: " EMAIL

  if [[ -n "${EMAIL}" ]]; then
    certbot --nginx --agree-tos --email "${EMAIL}" -d "${DOMAIN}" --non-interactive --redirect
  else
    certbot --nginx --agree-tos --register-unsafely-without-email -d "${DOMAIN}" --non-interactive --redirect
  fi

  if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    print_success "SSL 证书申请成功"
    nginx -t
    systemctl reload nginx
  else
    print_warning "未检测到证书文件，可能申请失败，请稍后手动检查"
  fi
else
  print_warning "已跳过 SSL 证书申请"
fi

echo
print_info "8/8 创建管理命令..."
cat > /usr/local/bin/substorectl <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /opt/sub-store/substore.env

case "${1:-}" in
  start)
    docker start sub-store
    ;;
  stop)
    docker stop sub-store
    ;;
  restart)
    docker restart sub-store
    ;;
  status)
    echo "=== Container ==="
    docker ps -a --filter "name=sub-store"
    echo
    echo "=== Docker logs (last 30 lines) ==="
    docker logs --tail 30 sub-store 2>/dev/null || true
    echo
    echo "=== Nginx ==="
    systemctl --no-pager --full status nginx || true
    echo
    echo "=== Local binding ==="
    ss -ltnp | grep ":${HOST_PORT} " || true
    ;;
  logs)
    docker logs -f sub-store
    ;;
  update)
    bash /opt/sub-store/update_substore.sh
    ;;
  info)
    echo "DOMAIN=${DOMAIN}"
    echo "HOST_PORT=${HOST_PORT}"
    echo "CONTAINER_PORT=${CONTAINER_PORT}"
    echo "API_PATH=${API_PATH}"
    echo "API_URL=${API_URL}"
    echo "DATA_DIR=${DATA_DIR}"
    ;;
  *)
    echo "用法: substorectl {start|stop|restart|status|logs|update|info}"
    exit 1
    ;;
esac
EOF
chmod +x /usr/local/bin/substorectl

if [[ "${ENABLE_AUTO_UPDATE}" =~ ^[Yy]$ ]]; then
  cat > /etc/cron.d/substore_update <<'EOF'
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
0 4 */3 * * root /opt/sub-store/update_substore.sh >> /var/log/substore_update.log 2>&1
EOF
  print_success "已启用每 3 天自动更新一次"
else
  rm -f /etc/cron.d/substore_update
  print_info "未启用自动更新。后续可手动执行: substorectl update"
fi

echo
print_success "部署完成"
echo
echo "域名访问地址:"
if [[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
  echo "  https://${DOMAIN}"
  echo "  订阅 API URL: ${API_URL}"
else
  echo "  http://${DOMAIN}"
  echo "  订阅 API URL: ${API_URL}"
fi
echo
echo "本地容器转发:"
echo "  127.0.0.1:${HOST_PORT} -> container:${CONTAINER_PORT}"
echo
echo "管理命令:"
echo "  substorectl status"
echo "  substorectl logs"
echo "  substorectl update"
echo "  substorectl info"
echo
echo "重要文件:"
echo "  环境文件: ${ENV_FILE}"
echo "  数据目录: ${DATA_DIR}"
echo "  Nginx 配置: ${NGINX_CONF}"
echo "  运行脚本: ${RUN_SCRIPT}"
echo "  更新脚本: ${UPDATE_SCRIPT}"
