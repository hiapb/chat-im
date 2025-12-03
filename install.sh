#!/usr/bin/env bash

set -e

INSTALL_DIR="/root/data/chatwoot"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
DOCKER_COMPOSE_CMD="docker compose"  

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

rand_pw() {
  # 生成相对安全且 YAML 友好的随机密码（无特殊符号）
  openssl rand -base64 24 2>/dev/null | tr -d '=+/' | cut -c1-24
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    red "请用 root 权限运行此脚本（sudo 或直接 root 用户）。"
    exit 1
  fi
}

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="$ID"
  else
    OS_ID="unknown"
  fi
}

install_pkg_generic() {
  local pkg="$1"
  # 尝试 apt / yum / dnf
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$pkg"
  else
    yellow "无法自动为你安装软件包 $pkg，请手动安装。"
  fi
}

install_docker_if_missing() {
  if command -v docker >/dev/null 2>&1; then
    yellow "已检测到 docker，跳过安装。"
    return
  fi

  yellow "未检测到 docker，使用官方脚本自动安装 Docker..."

  # 确保 curl 存在
  if ! command -v curl >/dev/null 2>&1; then
    yellow "未检测到 curl，正在自动安装 curl..."
    install_pkg_generic curl
  fi

  # 官方 Docker 安装脚本，支持 Debian/Ubuntu/CentOS 等主流发行版
  curl -fsSL https://get.docker.com | sh

  systemctl enable --now docker || true

  if ! command -v docker >/dev/null 2>&1; then
    red "Docker 安装失败，请检查网络或手动安装 Docker 后重试。"
    exit 1
  fi

  green "Docker 安装完成。"
}

ensure_docker_compose() {
  # 优先使用新命令 docker compose
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
    green "检测到 'docker compose' 子命令，将使用它。"
    return
  fi

  # 尝试旧版 docker-compose
  if command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker-compose"
    green "检测到 'docker-compose' 命令，将使用它。"
    return
  fi

  yellow "未检测到 docker compose / docker-compose，尝试安装 docker-compose 二进制..."

  local DEST="/usr/local/bin/docker-compose"
  local URL
  URL="https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-$(uname -s)-$(uname -m)"

  curl -L "$URL" -o "$DEST"
  chmod +x "$DEST"

  if ! command -v docker-compose >/dev/null 2>&1; then
    red "docker-compose 安装失败，请手动安装 docker-compose。"
    exit 1
  fi

  DOCKER_COMPOSE_CMD="docker-compose"
  green "docker-compose 安装完成，将使用 'docker-compose'。"
}

ensure_openssl() {
  if command -v openssl >/dev/null 2>&1; then
    return
  fi
  yellow "未检测到 openssl，正在自动安装 openssl..."
  install_pkg_generic openssl

  if ! command -v openssl >/dev/null 2>&1; then
    red "openssl 安装失败，请手动安装后重试。"
    exit 1
  fi
}

ensure_dependencies() {
  detect_os
  yellow "检测 / 安装依赖：Docker、docker-compose、openssl..."

  install_docker_if_missing
  ensure_docker_compose
  ensure_openssl
}

create_env_file() {
  mkdir -p "$INSTALL_DIR"

  green "开始配置 Chatwoot 环境变量 (.env)..."

  read -rp "请输入 Chatwoot 域名 (例如 chat.example.com，默认: chat.inim.im): " DOMAIN
  DOMAIN=${DOMAIN:-chat.inim.im}

  read -rp "请输入 Chatwoot 监听端口 (默认: 6698): " PORT
  PORT=${PORT:-6698}

  # 默认随机密码
  DEFAULT_PG_PASS=$(rand_pw)
  DEFAULT_REDIS_PASS=$(rand_pw)

  yellow "为你生成的默认 PostgreSQL 密码: $DEFAULT_PG_PASS"
  read -rp "PostgreSQL 密码 (直接回车使用上面生成的默认密码): " PG_PASS
  PG_PASS=${PG_PASS:-$DEFAULT_PG_PASS}

  yellow "为你生成的默认 Redis 密码: $DEFAULT_REDIS_PASS"
  read -rp "Redis 密码 (直接回车使用上面生成的默认密码): " REDIS_PASS
  REDIS_PASS=${REDIS_PASS:-$DEFAULT_REDIS_PASS}

  green "接下来需要 SECRET_KEY_BASE："
  echo "  你可以在另一个终端运行： openssl rand -hex 64"
  echo "  然后把结果粘贴到下面。"
  read -rp "请粘贴 SECRET_KEY_BASE (直接回车则自动生成): " SECRET_KEY_BASE

  if [ -z "$SECRET_KEY_BASE" ]; then
    SECRET_KEY_BASE=$(openssl rand -hex 64)
    yellow "已自动为你生成 SECRET_KEY_BASE。"
  fi

  cat > "$ENV_FILE" <<EOF
RAILS_ENV=production
INSTALLATION_ENV=docker

FRONTEND_URL=https://$DOMAIN
BACKEND_URL=https://$DOMAIN

SECRET_KEY_BASE=$SECRET_KEY_BASE

POSTGRES_HOST=postgres
POSTGRES_PORT=5432
POSTGRES_USERNAME=chatwoot
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DATABASE=chatwoot

REDIS_URL=redis://redis:6379
REDIS_PASSWORD=$REDIS_PASS

MAILER_SENDER_EMAIL=noreply@$DOMAIN
SMTP_ADDRESS=
SMTP_USERNAME=
SMTP_PASSWORD=
SMTP_DOMAIN=
SMTP_PORT=
SMTP_AUTHENTICATION=
SMTP_ENABLE_STARTTLS_AUTO=
EOF

  green ".env 文件已生成：$ENV_FILE"
  echo
  yellow "域名: $DOMAIN"
  yellow "端口: $PORT"
  yellow "PostgreSQL 密码: $PG_PASS"
  yellow "Redis 密码: $REDIS_PASS"

  # 把端口和域名记录下来，供 compose 和提示用
  echo "$PORT" > "$INSTALL_DIR/.port"
  echo "$DOMAIN" > "$INSTALL_DIR/.domain"
}

create_compose_file() {
  local PORT
  if [ -f "$INSTALL_DIR/.port" ]; then
    PORT=$(cat "$INSTALL_DIR/.port")
  else
    PORT=6698
  fi

  cat > "$COMPOSE_FILE" <<EOF
services:
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_DB: chatwoot
      POSTGRES_USER: chatwoot
      POSTGRES_PASSWORD: $(grep '^POSTGRES_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2-)
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    restart: always

  redis:
    image: redis:6.2
    command: ["sh", "-c", "redis-server --requirepass \"\$REDIS_PASSWORD\""]
    env_file: .env
    volumes:
      - ./data/redis:/data
    restart: always

  chatwoot:
    image: chatwoot/chatwoot:latest
    env_file: .env
    depends_on:
      - postgres
      - redis
    ports:
      - "${PORT}:3000"
    volumes:
      - ./data/storage:/app/storage
    restart: always
    command: >
      bundle exec rails s -p 3000 -b 0.0.0.0

  sidekiq:
    image: chatwoot/chatwoot:latest
    env_file: .env
    depends_on:
      - postgres
      - redis
    volumes:
      - ./data/storage:/app/storage
    restart: always
    command: >
      bundle exec sidekiq -C config/sidekiq.yml
EOF

  green "docker-compose.yml 已生成：$COMPOSE_FILE"
}

install_or_update() {
  ensure_dependencies
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  if [ -f "$ENV_FILE" ]; then
    yellow ".env 已存在，将复用现有配置。"
  else
    create_env_file
  fi

  create_compose_file

  # 确保干净的 postgres 数据目录（首次安装时）
  if [ ! -d "$INSTALL_DIR/data/postgres" ] || [ -z "$(ls -A "$INSTALL_DIR/data/postgres" 2>/dev/null || true)" ]; then
    yellow "初始化数据库..."
    mkdir -p "$INSTALL_DIR/data/postgres"
    $DOCKER_COMPOSE_CMD down || true
    $DOCKER_COMPOSE_CMD run --rm chatwoot bundle exec rails db:chatwoot_prepare
  else
    yellow "检测到已有数据库目录，跳过初始化步骤。"
  fi

  green "启动 Chatwoot 服务..."
  $DOCKER_COMPOSE_CMD up -d

  local PORT DOMAIN IP
  PORT=$(cat "$INSTALL_DIR/.port")
  if [ -f "$INSTALL_DIR/.domain" ]; then
    DOMAIN=$(cat "$INSTALL_DIR/.domain")
  fi
  IP=$(hostname -I 2>/dev/null | awk '{print $1}')

  echo
  green "Chatwoot 已启动成功！"
  if [ -n "$IP" ]; then
    echo "👉 本机访问地址：  http://${IP}:${PORT}"
  else
    echo "👉 本机访问地址：  http://服务器IP:${PORT}"
  fi
  if [ -n "$DOMAIN" ]; then
    echo "👉 如已配置反向代理 / HTTPS，可通过： https://${DOMAIN}  访问"
  fi
  echo
  yellow "首次访问时请在页面中创建管理员账号。"
}

show_status() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "未检测到安装目录：$INSTALL_DIR"
    return
  fi
  cd "$INSTALL_DIR"
  ensure_dependencies
  $DOCKER_COMPOSE_CMD ps
}

restart_service() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "未检测到安装目录：$INSTALL_DIR"
    return
  fi
  cd "$INSTALL_DIR"
  ensure_dependencies
  yellow "重启 Chatwoot 服务..."
  $DOCKER_COMPOSE_CMD down
  $DOCKER_COMPOSE_CMD up -d
  green "已重启。"
}

uninstall_all() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "未检测到 Chatwoot 安装目录：$INSTALL_DIR"
    return
  fi

  echo
  yellow "⚠ 卸载将执行以下操作："
  echo "   1. 停止所有 Chatwoot 相关容器"
  echo "   2. 删除 Chatwoot 的容器"
  echo "   3. 删除 Chatwoot 的镜像："
  echo "        - chatwoot/chatwoot"
  echo "        - pgvector/pgvector"
  echo "        - redis（仅限本脚本自建）"
  echo "   4. 删除 Chatwoot 数据目录：$INSTALL_DIR"
  echo "   5. 删除 Chatwoot 网络（如存在）"
  echo "   6. 不会卸载 Docker，如需卸载请手动执行"
  echo

  read -rp "确认卸载 Chatwoot 并删除所有数据？(yes/[no]): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    yellow "已取消卸载。"
    return
  fi

  cd "$INSTALL_DIR"
  ensure_dependencies

  yellow "停止 & 删除容器..."
  $DOCKER_COMPOSE_CMD down --rmi all --volumes --remove-orphans || true

  yellow "尝试清理残留容器..."
  docker rm -f chatwoot-chatwoot-1 chatwoot-sidekiq-1 chatwoot-postgres-1 chatwoot-redis-1 2>/dev/null || true

  yellow "尝试删除镜像（如果存在）..."
  docker rmi -f chatwoot/chatwoot:latest 2>/dev/null || true
  docker rmi -f pgvector/pgvector:pg16 2>/dev/null || true
  docker rmi -f redis:6.2 2>/dev/null || true

  yellow "尝试删除 Chatwoot 网络..."
  docker network rm chatwoot_default 2>/dev/null || true

  cd /
  yellow "删除 Chatwoot 数据目录..."
  rm -rf "$INSTALL_DIR"

  green "Chatwoot 已彻底卸载！"
  yellow "如需卸载 Docker，请手动卸载"
}

show_menu() {
  while true; do
    echo
    green "====== Chatwoot 管理菜单 ======"
    echo "1) 安装 Chatwoot"
    echo "2) 查看状态"
    echo "3) 重启服务"
    echo "4) 卸载"
    echo "5) 退出"
    read -rp "请选择 [1-5]: " CHOICE
    case "$CHOICE" in
      1) install_or_update ;;
      2) show_status ;;
      3) restart_service ;;
      4) uninstall_all ;;
      5) exit 0 ;;
      *) yellow "无效选项，请重新输入。" ;;
    esac
  done
}

main() {
  check_root
  show_menu
}

main "$@"
