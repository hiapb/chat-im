#!/usr/bin/env bash

# hia Chatwoot 一键管理脚本 v4.5
# 自动安装 Docker、Compose、OpenSSL

set -e

INSTALL_DIR="/root/data/chatwoot"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
DOCKER_COMPOSE_CMD="docker compose"

########################################
# 彩色输出
########################################

green() { printf "\033[32m%s\033[0m\n" "$*"; }
red()   { printf "\033[31m%s\033[0m\n" "$*"; }
yellow(){ printf "\033[33m%s\033[0m\n" "$*"; }
blue()  { printf "\033[36m%s\033[0m\n" "$*"; }

rand_pw() {
  openssl rand -base64 24 2>/dev/null | tr -d '=+/' | cut -c1-24
}

check_root() {
  if [ "$EUID" -ne 0 ]; then
    red "✖ 必须使用 root 权限运行此脚本"
    exit 1
  fi
}

########################################
# 自动安装依赖
########################################

detect_os() {
  [ -f /etc/os-release ] && . /etc/os-release || ID="unknown"
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
    yellow "⚠ 系统不支持自动安装 $pkg，请手动安装"
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1; then return; fi

  blue "🔧 未检测到 Docker，正在安装..."
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

  blue "🔧 未检测到 docker compose，正在安装..."
  local URL="https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-$(uname -s)-$(uname -m)"
  curl -L "$URL" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose

  command -v docker-compose >/dev/null 2>&1 || { red "✖ docker-compose 安装失败"; exit 1; }
  DOCKER_COMPOSE_CMD="docker-compose"
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
# 创建配置文件
########################################

create_env() {
  mkdir -p "$INSTALL_DIR"

  # 🌍 域名必须输入，不能为空
  while true; do
    read -rp "🌍 请输入 Chatwoot 域名（例如：chat.example.com）： " DOMAIN
    [[ -n "$DOMAIN" ]] && break
    red "✖ 域名不能为空，请重新输入"
  done

  read -rp "📦 请输入端口（默认 6698）： " PORT
  PORT=${PORT:-6698}

  DEFAULT_PG_PASS=$(rand_pw)
  read -rp "🔒 PostgreSQL 密码（回车随机生成）： " PG_PASS
  PG_PASS=${PG_PASS:-$DEFAULT_PG_PASS}

  DEFAULT_REDIS_PASS=$(rand_pw)
  read -rp "🔒 Redis 密码（回车随机生成）： " REDIS_PASS
  REDIS_PASS=${REDIS_PASS:-$DEFAULT_REDIS_PASS}

  read -rp "🔑 SECRET_KEY_BASE（回车自动生成）： " SECRET_KEY_BASE
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

  green "✔ .env 配置文件创建成功"
}

########################################
# 创建 docker-compose
########################################

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

  green "✔ docker-compose.yml 生成完成"
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
    $DOCKER_COMPOSE_CMD run --rm chatwoot bundle exec rails db:chatwoot_prepare
  fi

  $DOCKER_COMPOSE_CMD up -d

  PORT=$(cat "$INSTALL_DIR/.port")
  DOMAIN=$(cat "$INSTALL_DIR/.domain")
  IP=$(hostname -I | awk '{print $1}')

  green "✔ Chatwoot 已成功启动"
  echo "🌍 服务器访问地址：http://${IP}:${PORT}"
  echo "🔗 反代后域名访问：https://${DOMAIN}"
}

########################################
# 查看状态
########################################

show_status() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "✖ Chatwoot 未安装"
    return
  fi
  cd "$INSTALL_DIR"
  ensure_dependencies
  $DOCKER_COMPOSE_CMD ps
}

########################################
# 重启服务
########################################

restart_service() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "✖ Chatwoot 未安装"
    return
  fi
  cd "$INSTALL_DIR"
  ensure_dependencies
  $DOCKER_COMPOSE_CMD down
  $DOCKER_COMPOSE_CMD up -d
  green "✔ Chatwoot 服务已重启"
}

########################################
# 更新 Chatwoot
########################################

update_chatwoot() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "✖ Chatwoot 未安装，无法执行更新"
    return
  fi

  yellow "⚠ 即将开始更新 Chatwoot 最新版本..."
  yellow "【重要提醒】在执行更新前，强烈建议您已做好数据备份！"
  read -rp "❓ 确认继续执行更新流程？[y/N]： " CONFIRM

  case "$CONFIRM" in
    y|Y) ;;
    *) yellow "⚠ 为了数据安全，已取消更新"; return ;;
  esac

  cd "$INSTALL_DIR"
  ensure_dependencies

  blue "⬇ 正在从 Docker Hub 拉取最新镜像..."
  $DOCKER_COMPOSE_CMD pull

  blue "🔄 正在执行数据库迁移与结构同步 (db:chatwoot_prepare)..."
  $DOCKER_COMPOSE_CMD run --rm chatwoot bundle exec rails db:chatwoot_prepare

  blue "🚀 正在重启系统以应用最新版本..."
  $DOCKER_COMPOSE_CMD down
  $DOCKER_COMPOSE_CMD up -d

  green "✔ Chatwoot 更新已顺利完成！"
}

########################################
# 卸载 Chatwoot
########################################

uninstall_all() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "✖ Chatwoot 未安装"
    return
  fi

  yellow "⚠ 卸载将删除 Chatwoot 所有数据、容器、镜像！"
  read -rp "❓ 确认卸载 Chatwoot？[y/N]：" CONFIRM

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

  green "✔ Chatwoot 已彻底卸载，脚本将退出。"

  exit 0
}

########################################
# 菜单系统
########################################

show_menu() {
  while true; do
    echo
    green "========= Chatwoot 管理菜单 ========="
    echo "1) 🌍 安装 Chatwoot"
    echo "2) 📊 查看状态"
    echo "3) 🔄 重启服务"
    echo "4) ⬆️ 更新 Chatwoot"
    echo "5) 🧹 卸载 Chatwoot"
    echo "6) ❌ 退出"
    read -rp "请选择 [1-6]： " CHOICE

    case "$CHOICE" in
      1) install_or_update ;;
      2) show_status ;;
      3) restart_service ;;
      4) update_chatwoot ;;
      5) uninstall_all ;;
      6) exit 0 ;;
      *) yellow "⚠ 无效选择，请重新输入" ;;
    esac
  done
}

main() {
  check_root
  show_menu
}

main "$@"
