#!/usr/bin/env bash
# Stb 图床一键部署脚本 · MIT License © 2026 鼠宝财
# 上游：https://github.com/setube/stb （Apache-2.0）
set -euo pipefail

TOOL_VERSION="1.0.0"
APP_NAME="Stb 图床"
PROJECT="stb"
INSTALL_DIR="/opt/stb"
WEB_PORT=25519
ADMIN_USER="admin"
ADMIN_PASS=""
SITE_TITLE=""
SELFTEST=0
RECREATE=0
ASSUME_YES=0
ACTION="install"
DC=""
STB_IMAGE="${STB_IMAGE:-setube/stb:latest}"
MONGO_IMAGE="${MONGO_IMAGE:-mongo:7}"

if [ -t 1 ]; then
  R=$'\033[0m'; D=$'\033[2m'; RD=$'\033[31m'; GR=$'\033[32m'; YL=$'\033[33m'; BL=$'\033[36m'; BD=$'\033[1m'
else
  R=""; D=""; RD=""; GR=""; YL=""; BL=""; BD=""
fi
step() { printf '\n%s▸ %s%s\n' "$BD$BL" "$*" "$R"; }
info() { printf '  %s\n' "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GR" "$R" "$*"; }
warn() { printf '  %s!%s %s\n' "$YL" "$R" "$*"; }
err()  { printf '  %s✗%s %s\n' "$RD" "$R" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<EOF
${BD}${APP_NAME} 一键部署脚本${R}  v${TOOL_VERSION}
自托管图床：多用户 / 角色组 / 相册 / API / 水印压缩 / 10 种存储后端（含 Telegram）

${BD}用法${R}
  bash install_stb.sh [选项]

${BD}选项${R}
  --dir PATH         安装目录（默认 ${INSTALL_DIR}）
  --port N           对外端口（默认 ${WEB_PORT}）
  --admin-user NAME  管理员用户名（默认 ${ADMIN_USER}）
  --admin-pass PASS  管理员密码（默认随机生成 SBC+8位十六进制）
  --title TEXT       站点名称（写入数据库，可在后台改）
  --selftest         装完自动上传一张测试图验证全链路
  --recreate         强制重建容器（残留容器不健康时用；默认仅在检测到 unhealthy 时自动重建）
  --upgrade          拉取最新镜像并重建容器（数据保留）
  --uninstall        卸载：删除容器、数据卷、数据目录（需 --yes）
  --yes              不询问（用于 --uninstall）
  -h, --help         显示本帮助

${BD}部署形态${R}
  容器 stb（官方镜像 setube/stb）+ stb-mongo（MongoDB 7，缓存限制 0.25G）
  数据 ${INSTALL_DIR}/data/{uploads,mongo}
  凭据 ${INSTALL_DIR}/.credentials（600，含管理员密码与 JWT 密钥）
  首次访问注册的第一个账号即管理员；本脚本会自动建好并写入凭据文件

${BD}示例${R}
  bash install_stb.sh                                  # 默认 25519 端口
  bash install_stb.sh --port 8081 --selftest            # 8081 + 自动上传测试
  bash install_stb.sh --admin-pass 'MyPass123'          # 指定管理员密码
  bash install_stb.sh --upgrade                         # 升级到最新镜像
  bash install_stb.sh --uninstall --yes                 # 彻底卸载
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dir)         INSTALL_DIR="${2:?}"; shift 2 ;;
    --port)        WEB_PORT="${2:?}"; shift 2 ;;
    --admin-user)  ADMIN_USER="${2:?}"; shift 2 ;;
    --admin-pass)  ADMIN_PASS="${2:?}"; shift 2 ;;
    --title)       SITE_TITLE="${2:?}"; shift 2 ;;
    --selftest)    SELFTEST=1; shift ;;
    --recreate)    RECREATE=1; shift ;;
    --upgrade)     ACTION="upgrade"; shift ;;
    --uninstall)   ACTION="uninstall"; shift ;;
    --yes|-y)      ASSUME_YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             err "未知参数：$1"; echo; usage; exit 1 ;;
  esac
done
case "$WEB_PORT" in ''|*[!0-9]*) die "端口必须是数字：$WEB_PORT" ;; esac

require_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行（sudo bash $0 ...）"; }
port_busy()     { ss -ltnH "sport = :$1" 2>/dev/null | grep -q .; }
detect_ip() {
  local ip=""
  for u in https://api.ipify.org https://ifconfig.me/ip https://ip.sb; do
    ip="$(curl -s -4 --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]')" || true
    case "$ip" in *[!0-9.]*|"") ip="" ;; *) break ;; esac
  done
  [ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "${ip:-127.0.0.1}"
}

detect_pkg_mgr() {
  if command -v apt-get >/dev/null 2>&1; then echo apt
  elif command -v dnf >/dev/null 2>&1; then echo dnf
  elif command -v yum >/dev/null 2>&1; then echo yum
  else echo none; fi
}

ensure_base_pkgs() {
  step "检查基础依赖"
  local pm need=()
  pm="$(detect_pkg_mgr)"
  for c in curl openssl python3; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
  if [ "${#need[@]}" -eq 0 ]; then ok "curl / openssl / python3 均已就绪"; return; fi
  info "需要安装：${need[*]}"
  [ "$pm" = none ] && die "找不到包管理器，请手动安装：${need[*]}"
  case "$pm" in
    apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1 || true
         apt-get install -y -qq "${need[@]}" >/dev/null || die "依赖安装失败" ;;
    dnf) dnf install -y -q "${need[@]}" >/dev/null || die "依赖安装失败" ;;
    yum) yum install -y -q "${need[@]}" >/dev/null || die "依赖安装失败" ;;
  esac
  ok "基础依赖安装完成"
}

setup_docker_mirror() {
  [ -f /etc/docker/daemon.json ] && return
  if curl -s --max-time 3 http://metadata.tencentyun.com/latest/meta-data/ >/dev/null 2>&1; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": ["https://mirror.ccs.tencentyun.com"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
JSON
    info "已写入 Docker 镜像加速（腾讯云内网）"
  fi
}

ensure_docker() {
  step "检查 Docker"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    ok "Docker 已就绪：$(docker --version | cut -d, -f1)"
  else
    local pm; pm="$(detect_pkg_mgr)"
    [ "$pm" = none ] && die "请先安装 Docker：https://docs.docker.com/engine/install/"
    info "正在安装 Docker（自动探测软件源）…"
    case "$pm" in
      apt)
        export DEBIAN_FRONTEND=noninteractive
        local okd=0 m
        for m in "https://mirrors.tencentyun.com" "https://mirrors.cloud.tencent.com" \
                 "https://mirrors.aliyun.com" "https://mirrors.ustc.edu.cn" "https://deb.debian.org"; do
          info "尝试镜像源：$m"
          apt-get update -qq >/dev/null 2>&1 || true
          if apt-get install -y -qq docker.io >/dev/null 2>&1; then okd=1; break; fi
        done
        [ "$okd" -eq 1 ] || die "Docker 安装失败，请检查网络或手动安装"
        ;;
      dnf|yum) "$pm" install -y -q docker >/dev/null || die "Docker 安装失败" ;;
    esac
    systemctl enable --now docker >/dev/null 2>&1 || true
    ok "Docker 安装完成"
  fi
  setup_docker_mirror
  systemctl start docker >/dev/null 2>&1 || true
  if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
  else
    info "缺少 compose 插件，尝试安装…"
    case "$(detect_pkg_mgr)" in
      apt) apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 || true ;;
      dnf|yum) "$(detect_pkg_mgr)" install -y -q docker-compose-plugin >/dev/null 2>&1 || true ;;
    esac
    docker compose version >/dev/null 2>&1 && DC="docker compose" || die "compose 不可用，请安装 docker-compose-plugin"
  fi
  ok "compose 命令：$DC"
}

check_port() {
  step "检查端口"
  if port_busy "$WEB_PORT"; then
    if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "${PROJECT}.*:${WEB_PORT}->"; then
      ok "端口 ${WEB_PORT} 由本项目容器占用，将复用"
    else
      die "端口 ${WEB_PORT} 已被其它程序占用，请用 --port 换一个"
    fi
  else
    ok "端口 ${WEB_PORT} 空闲"
  fi
}

write_config() {
  step "生成配置"
  mkdir -p "$INSTALL_DIR/data/uploads" "$INSTALL_DIR/data/mongo"
  local cred="$INSTALL_DIR/.credentials"
  local jwt pass

  if [ -f "$cred" ]; then
    jwt="$(awk -F': ' '/^JWT_SECRET/{print $2}' "$cred" 2>/dev/null || true)"
    pass="$(awk -F': ' '/^管理员密码/{print $2}' "$cred" 2>/dev/null || true)"
    info "检测到已有凭据文件，复用 JWT 密钥与管理员密码"
  fi
  [ -n "${jwt:-}" ] || jwt="$(openssl rand -hex 32)"
  [ -n "${ADMIN_PASS}" ] || [ -n "${pass:-}" ] || ADMIN_PASS="SBC$(openssl rand -hex 4)"
  [ -n "${ADMIN_PASS}" ] || ADMIN_PASS="$pass"

  # Mongo 缓存：物理内存 1/8，限制在 256~512MB（MongoDB 要求 >= 0.25GB，低于会被拒绝启动）
  local mem_mb cache_mb cache_gb
  mem_mb="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
  cache_mb=$((mem_mb / 8))
  [ "$cache_mb" -lt 256 ] && cache_mb=256
  [ "$cache_mb" -gt 512 ] && cache_mb=512
  cache_gb="$(awk "BEGIN{c=$cache_mb/1024; if(c<0.25) c=0.25; printf \"%.2f\", c}")"

  cat > "$INSTALL_DIR/docker-compose.yml" <<YAML
services:
  stb:
    image: ${STB_IMAGE}
    container_name: stb
    restart: unless-stopped
    ports:
      - "${WEB_PORT}:25519"
    environment:
      PORT: "25519"
      MONGODB_URI: "mongodb://mongo:27017/stb"
      JWT_SECRET: "${jwt}"
      TZ: Asia/Shanghai
    volumes:
      - ./data/uploads:/app/server/uploads
    depends_on:
      mongo:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:25519/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s

  mongo:
    image: ${MONGO_IMAGE}
    container_name: stb-mongo
    restart: unless-stopped
    command: ["--wiredTigerCacheSizeGB", "${cache_gb}"]
    volumes:
      - ./data/mongo:/data/db
    environment:
      TZ: Asia/Shanghai
    healthcheck:
      test: ["CMD-SHELL", "mongosh --quiet --eval 'db.runCommand({ping:1}).ok' | grep 1"]
      interval: 10s
      timeout: 5s
      retries: 10
      start_period: 20s
YAML

  cat > "$cred" <<CRED
# ${APP_NAME} 部署凭据（勿外传）
访问地址: http://$(detect_ip):${WEB_PORT}
管理员账号: ${ADMIN_USER}
管理员密码: ${ADMIN_PASS}
JWT_SECRET: ${jwt}
安装目录: ${INSTALL_DIR}
数据目录: ${INSTALL_DIR}/data
Mongo 缓存: ${cache_mb}MB（物理内存 ${mem_mb}MB）
创建时间: $(date '+%F %T')
CRED
  chmod 600 "$cred"
  ok "compose 与凭据已生成（${cred}）"
  info "Mongo 缓存限制：${cache_mb}MB"
}

pull_images() {
  step "拉取镜像"
  ( cd "$INSTALL_DIR" && $DC -p "$PROJECT" pull ) 2>&1 | tail -4 | sed 's/^/  /' || warn "拉取失败，下面启动时会重试"
  ok "镜像：$(docker images --format '{{.Repository}}:{{.Tag}}({{.Size}})' | grep -E 'setube/stb|mongo:7' | tr '\n' ' ')"
}

wait_http() {
  local i code
  for i in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${WEB_PORT}/" || true)"
    [ "$code" = "200" ] && { ok "服务已就绪（HTTP 200）"; return 0; }
    sleep 3
  done
  warn "等待超时，排查：cd $INSTALL_DIR && $DC -p $PROJECT logs --tail 80 stb"
  return 1
}

load_existing_port() {
  [ -f "$INSTALL_DIR/docker-compose.yml" ] || return 0
  local p
  p="$(sed -n 's/.*"\([0-9][0-9]*\):25519".*/\1/p' "$INSTALL_DIR/docker-compose.yml" | head -1)"
  [ -n "$p" ] && WEB_PORT="$p"
}

compose_up() {
  step "启动容器"
  local recreate=""
  if [ "$RECREATE" -eq 1 ]; then
    recreate="--force-recreate"
    info "按 --recreate 强制重建容器"
  elif docker ps -a --format '{{.Names}}' | grep -qx stb && [ "$(docker inspect -f '{{.State.Health.Status}}' stb 2>/dev/null)" = "unhealthy" ]; then
    recreate="--force-recreate"
    info "检测到上次容器 unhealthy，强制重建"
  fi
  if ! ( cd "$INSTALL_DIR" && $DC -p "$PROJECT" up -d $recreate ) 2>&1 | tail -8 | sed 's/^/  /'; then
    return 1
  fi
  wait_http
}

mongo_eval() {
  ( cd "$INSTALL_DIR" && $DC -p "$PROJECT" exec -T mongo mongosh --quiet stb --eval "$1" ) < /dev/null 2>/dev/null
}

mongo_script() {
  cat > /tmp/.stb.js
  ( cd "$INSTALL_DIR" && $DC -p "$PROJECT" exec -T mongo mongosh --quiet stb ) < /tmp/.stb.js 2>/tmp/.stb_mongo.err \
    | sed 's/^stb> //' | grep -v '^$'
  local rc=${PIPESTATUS[0]}
  rm -f /tmp/.stb.js
  [ "$rc" -eq 0 ] || { warn "mongo 执行失败：$(tail -2 /tmp/.stb_mongo.err 2>/dev/null | tr '\n' ' ')"; return 1; }
  return 0
}

bootstrap() {
  step "初始化站点"
  local users token
  users="$(mongo_eval 'print(db.users.countDocuments())' | tr -d '[:space:]')"
  if [ "${users:-0}" = "0" ]; then
    curl -s -m 20 -X POST -H 'Content-Type: application/json' \
      -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\",\"email\":\"${ADMIN_USER}@example.com\"}" \
      "http://127.0.0.1:${WEB_PORT}/api/auth/register" > /tmp/.stb_reg.json || true
    token="$(python3 -c 'import json;print(json.load(open("/tmp/.stb_reg.json")).get("token",""))' 2>/dev/null || true)"
    if [ -n "${token}" ]; then
      ok "管理员已创建：${ADMIN_USER}（第一个注册账号自动成为创始人）"
      curl -s -m 10 -X POST -H "Authorization: Bearer ${token}" "http://127.0.0.1:${WEB_PORT}/api/auth/info" \
        | python3 -c 'import json,sys;d=json.load(sys.stdin);r=d.get("role") or {};print("  身份校验：isAdmin=%s founder=%s" % (r.get("isAdmin"), d.get("founder")))' 2>/dev/null || true
    else
      warn "自动建号失败，可打开网页手动注册（第一个账号即管理员）"
    fi
    rm -f /tmp/.stb_reg.json
  else
    info "已有 ${users} 个用户，跳过建号（管理员密码见凭据文件）"
  fi

  local ip; ip="$(detect_ip)"
  {
    cat <<'JS'
var _u1 = db.rolegroups.updateOne({isAdmin:true},   {$set:{maxCapacity: 20480}});
var _u2 = db.rolegroups.updateOne({isDefault:true}, {$set:{maxCapacity: 5120}});
var _u3 = db.rolegroups.updateOne({isGuest:true},   {$set:{maxCapacity: 1024}});
JS
    if [ -n "$SITE_TITLE" ]; then
      printf "var _u4 = db.configs.updateOne({}, {\$set:{'site.title':%s}});\n" "'$SITE_TITLE'"
    fi
    printf "var _u5 = db.configs.updateOne({}, {\$set:{'site.url':'http://%s:%s'}});\n" "$ip" "$WEB_PORT"
    cat <<'JS'
print('角色组容量: ' + db.rolegroups.find({},{name:1,maxCapacity:1}).toArray().map(function(r){return r.name+'='+r.maxCapacity}).join(', '));
print('站点URL: ' + db.configs.findOne({}).site.url);
JS
  } | mongo_script | sed 's/^/  /'
  ok "角色组容量与站点 URL 已修正（上游默认 maxCapacity=0 会拒绝上传）"
}

selftest() {
  step "自检：上传一张测试图"
  python3 - <<'PY'
import zlib, struct
w, h = 480, 240
raw = b''
for y in range(h):
    row = b'\x00'
    for x in range(w):
        row += bytes((int(255*x/w), int(180*y/h)+40, 210))
    raw += row
def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t+d) & 0xffffffff)
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) \
      + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')
open('/tmp/.stb_test.png', 'wb').write(png)
PY
  local code json
  code="$(curl -s -o /tmp/.stb_up.json -w '%{http_code}' -m 30 \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"username\":\"${ADMIN_USER}\",\"password\":\"${ADMIN_PASS}\"}" \
    "http://127.0.0.1:${WEB_PORT}/api/auth/login" || true)"
  local jwt
  jwt="$(python3 -c 'import json;print(json.load(open("/tmp/.stb_up.json")).get("token",""))' 2>/dev/null || true)"
  [ -n "$jwt" ] || { warn "登录失败，跳过自检"; rm -f /tmp/.stb_test.png /tmp/.stb_up.json; return 0; }
  code="$(curl -s -o /tmp/.stb_up2.json -w '%{http_code}' -m 30 -X POST -H "Authorization: Bearer $jwt" \
    -F "image=@/tmp/.stb_test.png" "http://127.0.0.1:${WEB_PORT}/api/upload" || true)"
  if [ "$code" = "201" ] || [ "$code" = "200" ]; then
    python3 - "$WEB_PORT" <<'PY'
import json, sys, urllib.request
port = sys.argv[1]
d = json.load(open('/tmp/.stb_up2.json'))
url = d.get('url', '')
full = url if url.startswith('http') else f'http://127.0.0.1:{port}{url}'
try:
    with urllib.request.urlopen(full, timeout=10) as r:
        n = len(r.read())
    print(f'  上传成功 ✓  {url}')
    print(f'  访问成功 ✓  HTTP {r.status}  {n} 字节')
except Exception as e:
    print(f'  上传成功但访问失败：{e}')
PY
  else
    warn "自检上传失败（HTTP ${code}）：$(head -c 200 /tmp/.stb_up2.json)"
  fi
  rm -f /tmp/.stb_test.png /tmp/.stb_up.json /tmp/.stb_up2.json
}

summary() {
  local ip; ip="$(detect_ip)"
  echo
  printf '%s%s%s\n' "$D" "────────────────────────────────────────────────────────────" "$R"
  printf '%s %s 部署完成%s\n' "$BD$GR" "$APP_NAME" "$R"
  printf '%s%s%s\n' "$D" "────────────────────────────────────────────────────────────" "$R"
  printf '  访问地址   %shttp://%s:%s/%s\n' "$BD" "$ip" "$WEB_PORT" "$R"
  printf '  管理入口   %s（登录后右上角进后台）\n' "http://${ip}:${WEB_PORT}/"
  printf '  管理员     %s / %s\n' "$ADMIN_USER" "$ADMIN_PASS"
  printf '  凭据文件   %s/.credentials（600）\n' "$INSTALL_DIR"
  printf '  数据目录   %s/data（uploads 图片 / mongo 数据库）\n' "$INSTALL_DIR"
  echo
  printf '  %s必须放行%s %s 端口（云厂商安全组），否则只有服务器本机可访问\n' "$BD$YL" "$R" "$WEB_PORT"
  printf '  %s安全提醒%s\n' "$BD$YL" "$R"
  printf '    · 默认开放注册，公网使用建议到后台关掉注册 / 改邀请码制\n'
  printf '    · 管理员密码是随机生成的，登录后建议在「个人设置」里改成自己的\n'
  printf '    · 上游为 Apache-2.0；抓取/存储内容请自行确认合规\n'
  echo
  printf '  %s常用命令%s\n' "$BD" "$R"
  printf '    日志    cd %s && %s -p %s logs -f stb\n' "$INSTALL_DIR" "$DC" "$PROJECT"
  printf '    重启    cd %s && %s -p %s restart\n' "$INSTALL_DIR" "$DC" "$PROJECT"
  printf '    备份    tar czf /root/stb-backup-$(date +%%F).tar.gz -C %s data\n' "$INSTALL_DIR"
  printf '    升级    bash %s --upgrade\n' "$0"
  printf '    卸载    bash %s --uninstall --yes\n' "$0"
  echo
  printf '  %s上游 setube/stb（Apache-2.0）· 本脚本 MIT © 2026 鼠宝财%s\n' "$D" "$R"
  echo
}

cmd_upgrade() {
  require_root; ensure_docker
  [ -f "$INSTALL_DIR/docker-compose.yml" ] || die "找不到 $INSTALL_DIR/docker-compose.yml"
  load_existing_port
  step "拉取最新镜像"
  ( cd "$INSTALL_DIR" && $DC -p "$PROJECT" pull ) 2>&1 | tail -3 | sed 's/^/  /' || warn "拉取失败，继续使用现有镜像"
  step "重建容器（端口 ${WEB_PORT}）"
  ( cd "$INSTALL_DIR" && $DC -p "$PROJECT" up -d ) 2>&1 | tail -5 | sed 's/^/  /'
  wait_http
  ok "升级完成（数据保留在 $INSTALL_DIR/data）"
  exit 0
}

cmd_uninstall() {
  require_root
  step "卸载 $APP_NAME"
  info "将删除：容器、Mongo 数据、上传的图片、$INSTALL_DIR"
  if [ "$ASSUME_YES" -ne 1 ]; then
    if [ -t 0 ]; then
      printf '  确认卸载？输入 yes 继续：'
      read -r a; [ "$a" = "yes" ] || { info "已取消"; exit 0; }
    else
      die "非交互环境请加 --yes"
    fi
  fi
  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    ( cd "$INSTALL_DIR" && $DC -p "$PROJECT" down -v 2>/dev/null ) || true
  fi
  docker rm -f stb stb-mongo >/dev/null 2>&1 || true
  rm -rf "$INSTALL_DIR"
  ok "已卸载（如需删镜像：docker rmi setube/stb:latest mongo:7）"
  exit 0
}

main() {
  [ "$ACTION" = "uninstall" ] && cmd_uninstall
  [ "$ACTION" = "upgrade" ]   && cmd_upgrade
  require_root
  printf '\n%s %s 一键部署%s  v%s\n' "$BD" "$APP_NAME" "$R" "$TOOL_VERSION"
  info "安装目录：$INSTALL_DIR    对外端口：$WEB_PORT"
  ensure_base_pkgs
  ensure_docker
  check_port
  write_config
  pull_images
  if ! compose_up; then
    echo
    printf '%s部署未完成%s\n' "$BD$RD" "$R"
    printf '  排查日志   cd %s && %s -p %s logs --tail 100 stb\n' "$INSTALL_DIR" "$DC" "$PROJECT"
    printf '  修复后重跑 bash %s --port %s（镜像会续传、数据与凭据会复用）\n' "$0" "$WEB_PORT"
    printf '  强制重建容器 bash %s --port %s --recreate\n' "$0" "$WEB_PORT"
    exit 1
  fi
  bootstrap
  [ "$SELFTEST" -eq 1 ] && selftest
  summary
}

main "$@"
