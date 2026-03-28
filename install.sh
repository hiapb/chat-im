#!/usr/bin/env bash

# hia Chatwoot 一键管理脚本 v5.0
# 自动安装 Docker、Compose、OpenSSL
# 深度集成：平滑更新、零宕机热备、跨机恢复、独立定时器与 FTP 异地链路

set -e

INSTALL_DIR="/root/data/chatwoot"
ENV_FILE="$INSTALL_DIR/.env"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
DOCKER_COMPOSE_CMD="docker compose"

CRON_TAG_BEGIN="# CHATWOOT_BACKUP_BEGIN"
CRON_TAG_END="# CHATWOOT_BACKUP_END"
BACKUP_LOG="/var/log/chatwoot_backup.log"

########################################
# 彩色输出与基础工具
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

get_local_ip() {
  hostname -I | awk '{print $1}' || echo "127.0.0.1"
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
    command: ["sh", "-c", "redis-server --requirepass \"\$REDIS_PASSWORD\""]
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
# 安装 / 状态 / 重启 / 更新
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
  IP=$(get_local_ip)

  green "✔ Chatwoot 已成功启动"
  echo "🌍 服务器访问地址：http://${IP}:${PORT}"
  echo "🔗 反代恢复域名：https://${DOMAIN}"
}

show_status() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "✖ Chatwoot 未安装"
    return
  fi
  cd "$INSTALL_DIR"
  ensure_dependencies
  $DOCKER_COMPOSE_CMD ps
}

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
    *) yellow "⚠ 已取消更新"; return ;;
  esac

  cd "$INSTALL_DIR"
  ensure_dependencies

  blue "⬇ 正在从 Docker Hub 拉取最新镜像..."
  $DOCKER_COMPOSE_CMD pull

  blue "🔄 正在执行数据库迁移与结构同步..."
  $DOCKER_COMPOSE_CMD run --rm chatwoot bundle exec rails db:chatwoot_prepare

  blue "🚀 正在重启系统以应用最新版本..."
  $DOCKER_COMPOSE_CMD down
  $DOCKER_COMPOSE_CMD up -d

  green "✔ Chatwoot 更新已顺利完成！"
}

########################################
# 手动备份 / 恢复备份 / 定时备份
########################################

do_backup() {
  if [ ! -d "$INSTALL_DIR" ]; then
    red "✖ 未检测到 Chatwoot，无法执行备份。"
    return
  fi
  
  local BACKUP_DIR="${INSTALL_DIR}/backups"
  mkdir -p "$BACKUP_DIR"
  local TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  local BACKUP_FILE="${BACKUP_DIR}/chatwoot_backup_${TIMESTAMP}.tar.gz"
  
  blue "🔄 开始执行手动备份..."
  cd "$INSTALL_DIR" || return
  
  # 逻辑备份保证数据一致性，防止直接打包物理文件导致的损坏
  if $DOCKER_COMPOSE_CMD ps | grep -q postgres; then
      blue "📦 正在导出数据库结构..."
      $DOCKER_COMPOSE_CMD exec -T postgres pg_dump -U chatwoot chatwoot > ./data/chatwoot_logical_dump.sql || yellow "⚠ 数据库导出警告，尝试继续文件备份"
  fi
  
  local TARGET_FILES=$(ls -A | grep -E 'docker-compose.yml|\.env|\.port|\.domain|data' || true)
  if [[ -z "$TARGET_FILES" ]]; then
    red "✖ 未找到核心配置或数据目录，备份终止。"
    return
  fi
  
  tar -czf "$BACKUP_FILE" $TARGET_FILES
  
  # 仅保留最近 3 份快照
  cd "$BACKUP_DIR" || return
  ls -t chatwoot_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -I {} rm -f {}
  
  green "✔ 备份执行完毕。当前可用备份如下："
  for f in $(ls -t chatwoot_backup_*.tar.gz 2>/dev/null); do
    local fsize=$(du -h "$f" | cut -f1)
    echo -e "  📦 \033[36m${BACKUP_DIR}/${f}\033[0m (大小: ${fsize})"
  done
}

restore_backup() {
  blue "== 恢复备份 =="
  
  local DEFAULT_BACKUP=""
  local SEARCH_DIR="${INSTALL_DIR}/backups"
  
  if [[ -d "$SEARCH_DIR" ]]; then
    DEFAULT_BACKUP=$(ls -t "${SEARCH_DIR}"/chatwoot_backup_*.tar.gz 2>/dev/null | head -n 1 || true)
  fi
  
  local BACKUP_PATH=""
  if [[ -n "$DEFAULT_BACKUP" ]]; then
    echo -e "已自动找到最新备份: \033[33m${DEFAULT_BACKUP}\033[0m"
    read -rp "请输入备份文件路径 [直接回车使用默认]: " input_backup
    BACKUP_PATH=${input_backup:-$DEFAULT_BACKUP}
  else
    read -rp "请输入备份文件(.tar.gz)路径: " BACKUP_PATH
  fi
  
  if [[ ! -f "$BACKUP_PATH" ]]; then 
    red "✖ 未找到有效的备份文件，请检查路径。"
    return
  fi
  
  if [[ -d "$INSTALL_DIR" && -f "$INSTALL_DIR/docker-compose.yml" ]]; then
    yellow "⚠ 警告：当前已存在 Chatwoot 实例，恢复将覆盖现有数据！"
    read -rp "❓ 是否强制覆盖继续？(y/N): " FORCE_OVERRIDE
    if [[ ! "$FORCE_OVERRIDE" =~ ^[Yy]$ ]]; then
      green "✔ 已取消恢复流程。"
      return
    fi
    cd "$INSTALL_DIR" && $DOCKER_COMPOSE_CMD down || true
  fi
  
  mkdir -p "$INSTALL_DIR"
  blue "📦 正在解压备份数据..."
  tar -xzf "$BACKUP_PATH" -C "$INSTALL_DIR" || { red "✖ 解压失败，备份包可能损坏。"; return; }
  
  cd "$INSTALL_DIR" && ensure_dependencies
  
  blue "🚀 正在重新启动服务..."
  $DOCKER_COMPOSE_CMD up -d || { red "✖ 启动失败，请检查配置。"; return; }
  
  PORT=$(cat "$INSTALL_DIR/.port" 2>/dev/null || echo "6698")
  DOMAIN=$(cat "$INSTALL_DIR/.domain" 2>/dev/null || echo "未知")
  IP=$(get_local_ip)
  
  echo -e "\n=================================================="
  green "✅ Chatwoot 恢复完成！"
  echo -e "🌍 服务器访问地址：http://${IP}:${PORT}"
  echo -e "🔗 反代恢复域名：https://${DOMAIN}"
  echo -e "==================================================\n"
}

setup_auto_backup() {
  ensure_dependencies
  command -v crontab >/dev/null 2>&1 || install_pkg cron
  
  blue "== 定时备份设置 =="
  if [ ! -d "$INSTALL_DIR" ]; then
    red "✖ Chatwoot 未安装，无法设置定时备份。"
    return
  fi

  local CRON_SCRIPT="${INSTALL_DIR}/cron_backup.sh"
  local EXISTING_CRON="$(crontab -l 2>/dev/null | sed -n "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/p" | grep -v "^#" || true)"

  if [[ -n "$EXISTING_CRON" ]]; then
    yellow ">>> 发现当前正在运行的定时备份任务:"
    echo -e "\033[33m${EXISTING_CRON}\033[0m"
    read -rp "❓ 是否需要重新设置或覆盖该任务？(y/N): " RESET_CRON
    if [[ ! "$RESET_CRON" =~ ^[Yy]$ ]]; then
      return
    fi
  fi

  echo " 1) 按固定小时循环备份（例如：每 12 小时）"
  echo " 2) 按每日固定时间点备份（例如：每天 03:30）"
  echo " 3) 删除当前的定时备份任务"
  read -rp "请选择策略 [1-3]: " CRON_TYPE

  local CRON_SPEC=""
  if [[ "$CRON_TYPE" == "1" ]]; then
    CRON_SPEC="0 */12 * * *"
    blue "已设置为：每 12 小时备份一次。"
  elif [[ "$CRON_TYPE" == "2" ]]; then
    read -rp "请输入每天固定备份时间 (格式 HH:MM): " CRON_TIME
    if [[ ! "$CRON_TIME" =~ ^([0-1][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
      red "✖ 时间格式不正确。"
      return
    fi
    local HOUR="$(echo "${CRON_TIME%:*}" | sed 's/^0*//')"
    local MIN="$(echo "${CRON_TIME#*:}" | sed 's/^0*//')"
    [[ -z "$HOUR" ]] && HOUR="0"; [[ -z "$MIN" ]] && MIN="0"
    CRON_SPEC="${MIN} ${HOUR} * * *"
  elif [[ "$CRON_TYPE" == "3" ]]; then
    local TMP_CRON="$(mktemp)"
    crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$TMP_CRON" || true
    crontab "$TMP_CRON" 2>/dev/null || true
    rm -f "$TMP_CRON" "$CRON_SCRIPT"
    green "✔ 定时备份任务已被成功清理。"
    return
  else
    yellow "⚠ 无效选择" && return
  fi

  blue "正在生成独立的备份脚本..."
  cat > "$CRON_SCRIPT" << EOF
#!/usr/bin/env bash
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\$PATH"
INSTALL_DIR="${INSTALL_DIR}"
cd "\$INSTALL_DIR" || exit 1

BACKUP_DIR="\${INSTALL_DIR}/backups"
mkdir -p "\$BACKUP_DIR"
TIMESTAMP=\$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="\${BACKUP_DIR}/chatwoot_backup_\${TIMESTAMP}.tar.gz"

if command -v docker-compose >/dev/null 2>&1; then
    CMD="docker-compose"
else
    CMD="docker compose"
fi

\$CMD exec -T postgres pg_dump -U chatwoot chatwoot > ./data/chatwoot_logical_dump.sql || true

TARGET_FILES=\$(ls -A | grep -E 'docker-compose.yml|\.env|\.port|\.domain|data' || true)
if [[ -n "\$TARGET_FILES" ]]; then
    tar -czf "\$BACKUP_FILE" \$TARGET_FILES
    cd "\$BACKUP_DIR" || exit 1
    # 仅保留最近 3 份
    ls -t chatwoot_backup_*.tar.gz 2>/dev/null | awk 'NR>3' | xargs -I {} rm -f {}
fi
EOF
  chmod +x "$CRON_SCRIPT"

  local TMP_CRON="$(mktemp)"
  crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$TMP_CRON" || true
  cat >> "$TMP_CRON" <<EOF
${CRON_TAG_BEGIN}
${CRON_SPEC} bash ${CRON_SCRIPT} >> ${BACKUP_LOG} 2>&1
${CRON_TAG_END}
EOF
  crontab "$TMP_CRON" 2>/dev/null || true
  rm -f "$TMP_CRON"
  green "✔ 新的定时任务已成功添加。"
}

install_ftp(){
  clear
  echo -e "\033[32m📂 FTP/SFTP 备份工具...\033[0m"
  command -v curl >/dev/null 2>&1 || install_pkg curl
  bash <(curl -L https://raw.githubusercontent.com/hiapb/ftp/main/back.sh)
  sleep 2
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

  # 清理定时备份任务
  local TMP_CRON="$(mktemp)"
  crontab -l 2>/dev/null | sed "/^${CRON_TAG_BEGIN}$/,/^${CRON_TAG_END}$/d" > "$TMP_CRON" || true
  crontab "$TMP_CRON" 2>/dev/null || true
  rm -f "$TMP_CRON"

  green "✔ Chatwoot 已彻底卸载，脚本将退出。"
  exit 0
}

########################################
# 菜单系统
########################################

show_menu() {
  clear
  while true; do
    echo
    green "========= Chatwoot 管理菜单 ========="
    echo ""
    echo "1) 🌍 安装 Chatwoot"
    echo ""
    echo "2) 📊 查看状态"
    echo "3) 🔄 重启服务"
    echo "4) ⬆️ 更新 Chatwoot"
    echo ""
    echo "5) 💾 手动备份"
    echo "6) ⏪ 恢复备份"
    echo "7) ⏱️ 定时备份"
    echo "8) 📂 FTP/SFTP 备份工具"
    echo ""
    echo "9) 🧹 卸载 Chatwoot"
    echo "0) ❌ 退出"
    echo ""
    read -rp "请选择 [0-9]： " CHOICE

    case "$CHOICE" in
      1) install_or_update ;;
      2) show_status ;;
      3) restart_service ;;
      4) update_chatwoot ;;
      5) do_backup ;;
      6) restore_backup ;;
      7) setup_auto_backup ;;
      8) install_ftp ;;
      9) uninstall_all ;;
      0) exit 0 ;;
      *) yellow "⚠ 无效选择，请重试" ;;
    esac
  done
}

main() {
  check_root
  show_menu
}

main "$@"
