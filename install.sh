#!/usr/bin/env bash

# Chatwoot 一键管理脚本（完整版 v4.0）
# 自动安装 Docker、Compose、OpenSSL
# 支持安装/更新、重启、状态查看、彻底卸载（y/N）
# 优化输出符号（⚡ 提示 ✔ 成功 ✖ 错误 ⚠ 警告）

set -e

INSTALL_DIR="/root/data/chatwoot"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
DOCKER_COMPOSE_CMD="docker compose"  # 自动检测

########################################
# 彩色输出
########################################

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }

rand_pw() {
  openssl rand -base64 24 2>/dev/null | tr -d '=+/' | cut -c1-24
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    red "✖ 必须使用 root 权限运行此脚本。"
    exit 1
  fi
}

########################################
# 自动安装依赖
########################################

detect_os() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
  else
    ID="unknown"
  fi
}

install_pkg() {
  local pkg="$1"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y "$pkg"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$pkg"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$pkg"
  else
    yellow "⚠ 无法自动安装 $pkg，请手动安装。"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi

  yellow "⚡ 未检测到 Docker，正在安装..."
  command -v curl >/dev/null 2>&1 || install_pkg curl
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker || true

  command -v docker >/dev/null 2>&1 || { red "✖ Docker 安装失败"; exit 1; }
  green "✔ Docker 安装完成"
}

ensure_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    DOCKER_COMPOSE_CMD="docker-compose"
    return
  fi

  yellow "⚡ 未检测到 docker compose，安装中..."
  local URL="https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-$(uname -s)-$(uname -m)"
  curl -L "$URL" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  DOCKER_COMPOSE_CMD="docker-compose"

  command -v docker-compose >/dev/null 2>&1 || { red "✖ docker-compose 安装失败"; exit 1; }
  green "✔ docker-compose 安装完成"
}

ensure_openssl() {
  command -v openssl >/dev/null 2>&1 || install_pkg openssl
}

ensure_dependencies() {
  detect_os
  install_docker
  ensure_docker_compose
  ensure_openssl
}

########################################
# 创建配置
########################################

create_env() {
  mkdir -p "$INSTALL_DIR"

  read -rp "⚡ 输入 Chatwoot 域名（默认 chat.inim.im）：" DOMAIN
  DOMAIN=${DOMAIN:-chat.inim.im}

  read -rp "⚡ 输入端口（默认 6698）：" PORT
  PORT=${PORT:-6698}

  DEFAULT_PG_PASS=$(rand_pw)
  read -rp "⚡ PostgreSQL 密码（回车随机生成）：" PG_PASS
  PG_PASS=${PG_PASS:-$DEFAULT_PG_PASS}

  DEFAULT_REDIS_PASS=$(rand_pw)
  read -rp "⚡ Redis 密码（回车随机生成）：" REDIS_PASS
  REDIS_PASS=${REDIS_PASS:-$DEFAULT_REDIS_PASS}

  read -rp "⚡ SECRET_KEY_BASE（回车自动生成）：" SECRET_KEY_BASE
  SECRET_KEY_BASE=${SECRET_KEY_BASE:-$(openssl rand -hex 64)}

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
EOF

  echo "$PORT" > "$INSTALL_DIR/.port"
  echo "$DOMAIN" > "$INSTALL_DIR/.domain"

  green "✔ .env 已生成"
}

create_compose() {
  PORT=$(cat "$INSTALL_DIR/.port")
  PG_PASS=$(grep '^POSTGRES_PASSWORD=' "$ENV_FILE" | cut -d= -f2)

cat > "$COMPOSE_FILE" <<EOF
services:
  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_DB: chatwoot
      POSTGRES_USER: chatwoot
      POSTGRES_PASSWORD: $PG_PASS
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    restart: always

  redis:
    image: redis:6.2
    env_file: .env
    command: ["sh", "-c", "redis-server --requirepass \\"\$REDIS_PASSWORD\\""]
    volumes:
      - ./data/redis:/data
    restart: always

  chatwoot:
    image: chatwoot/chatwoot:latest
    env_file: .env
    depends_on: [postgres, redis]
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
    depends_on: [postgres, redis]
    volumes:
      - ./data/storage:/app/storage
    restart: always
    command: >
      bundle exec sidekiq -C config/sidekiq.yml
EOF

  green "✔ docker-compose.yml 已生成"
}

########################################
# 安装 / 启动
########################################

install_or_update() {
  ensure_dependencies
  mkdir -p "$INSTALL_DIR"
  cd "$INSTALL_DIR"

  [ -f "$ENV_FILE" ] || create_env
  create_compose

  if [ ! -d "$INSTALL_DIR/data/postgres" ]; then
    mkdir -p "$INSTALL_DIR/data/postgres"
    $DOCKER_COMPOSE_CMD down || true
    $DOCKER_COMPOSE_CMD run --rm chatwoot bundle exec rails db:chatwoot_prepare
  fi

  $DOCKER_COMPOSE_CMD up -d

  PORT=$(cat "$INSTALL_DIR/.port")
  DOMAIN=$(cat "$INSTALL_DIR/.domain")
  IP=$(hostname -I | awk '{print $1}')

  green "✔ Chatwoot 已启动"
  echo "⚡ 本机访问：http://${IP}:${PORT}"
  echo "⚡ 域名访问：https://${DOMAIN}"
}

########################################
# 状态
########################################

show_status() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "✖ 未检测到安装目录"
    return
  fi
  cd "$INSTALL_DIR"
  ensure_dependencies
  $DOCKER_COMPOSE_CMD ps
}

########################################
# 重启
########################################

restart_service() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "✖ 未检测到安装目录"
    return
  fi
  cd "$INSTALL_DIR"
  ensure_dependencies
  $DOCKER_COMPOSE_CMD down
  $DOCKER_COMPOSE_CMD up -d
  green "✔ Chatwoot 已重启"
}

########################################
# 卸载
########################################

uninstall_all() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "✖ 未检测到安装目录"
    return
  fi

  echo
  yellow "⚠ 卸载将删除所有 Chatwoot 数据、容器、镜像"
  read -rp "⚡ 确认卸载 Chatwoot？[y/N]：" CONFIRM
  case "$CONFIRM" in
    y|Y) ;;
    *) yellow "⚠ 已取消卸载"; return ;;
  esac

  cd "$INSTALL_DIR"
  ensure_dependencies

  $DOCKER_COMPOSE_CMD down --rmi all --volumes --remove-orphans || true

  docker rm -f chatwoot-chatwoot-1 chatwoot-sidekiq-1 chatwoot-postgres-1 chatwoot-redis-1 2>/dev/null || true

  docker rmi -f chatwoot/chatwoot:latest pgvector/pgvector:pg16 redis:6.2 2>/dev/null || true

  docker network rm chatwoot_default 2>/dev/null || true

  rm -rf "$INSTALL_DIR"

  green "✔ Chatwoot 已彻底卸载"
}

########################################
# 菜单
########################################

show_menu() {
  while true; do
    echo
    green "====== Chatwoot 管理菜单 ======"
    echo "1) 安装 Chatwoot"
    echo "2) 查看状态"
    echo "3) 重启服务"
    echo "4) 卸载 Chatwoot"
    echo "5) 退出"
    read -rp "请选择 [1-5]：" CHOICE
    case "$CHOICE" in
      1) install_or_update ;;
      2) show_status ;;
      3) restart_service ;;
      4) uninstall_all ;;
      5) exit 0 ;;
      *) yellow "⚠ 无效选项，请重新输入。" ;;
    esac
  done
}

main() {
  check_root
  show_menu
}

main "$@"
