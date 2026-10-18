#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hysteria2 节点一键安装 + 注册脚本
#
# 用法:
#   ./install.sh <运营商识别码>
#   ./install.sh --code 4f13b9d93a8afb6e98283702
#   ./install.sh --code <CODE> --dry-run          # 只打印将要写入的配置和上报内容
#   ./install.sh --register-only                  # 服务已装好，只重新上报注册信息
#   ./install.sh --verify-only                    # 只做健康检查（服务/端口/API）
#   ./install.sh --code <CODE> --gen-cert         # 强制重新生成证书对（旧的自备份）
#   ./install.sh --code <CODE> --template-url URL # 换标准模板接口
#   ./install.sh --code <CODE> --template-file P  # 离线：用本地模板文件（跳过拉取）
#
# 做的事:
#   0. 从面板拉标准版 config.yaml（GET /api/config-template；仓库里不再放模板，拉不到直接退出）
#   1. 用 <运营商识别码> 渲染 config.yaml（obfs salamander 密码 = 识别码）
#      - listen: ':443'
#      - trafficStats 监听 0.0.0.0:<随机 10000-19000>（自动避开已占用端口）
#      - trafficStats secret 随机 48 位 hex
#      - bandwidth up/down 100 mbps
#   2. 自动生成证书对 cert/key（EC P-256，10 年，SAN 含公网 IP 与主机名）
#      —— 脚本目录里放了 cert/key 就直接用；--gen-cert 强制重新生成（先备份）
#   3. 安装 hysteria 二进制 + systemd 单元；配置写完立刻重启（三者都没变才跳过重启）
#   4. 验证：服务 active、UDP 端口在听、trafficStats API 返回 200
#   5. 探测公网 IP，POST 到 https://hysteria.ipx.sarl/new
#      （失败只 WARN，不上报不算安装失败；payload 存在 <配置目录>/register.json）
#
# 环境变量（测试/特殊环境用）:
#   HYSTERIA_ETC=/etc/hysteria        HYSTERIA_BIN=/usr/local/bin/hysteria
#   HYSTERIA_SERVICE=hysteria-server  SYSTEMD_UNIT_DIR=/etc/systemd/system
#   MASQUERADE_DIR=/var/www/hysteria  HYSTERIA_LISTEN=:443
#   HYSTERIA_VERSION=v2.13.0          REG_API=https://hysteria.ipx.sarl/new
#   TEMPLATE_URL=https://hysteria.ipx.sarl/api/config-template  TEMPLATE_FILE=/path/config.yaml
#   REG_PAYLOAD='{"ip":"__IP__",...}'  # 自定义上报 JSON 模板
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HYSTERIA_VERSION="${HYSTERIA_VERSION:-v2.13.0}"
HYSTERIA_ETC="${HYSTERIA_ETC:-/etc/hysteria}"
CONFIG="${HYSTERIA_ETC}/config.yaml"
# 标准模板只从面板拉（平台后台「系统 → Hysteria 配置模板」可编辑保存，版本自增）。
# 离线/调试可给 TEMPLATE_FILE=/path/to/config.yaml 直接指定本地文件。
TEMPLATE_URL="${TEMPLATE_URL:-https://hysteria.ipx.sarl/api/config-template}"
TEMPLATE_FILE="${TEMPLATE_FILE:-}"
TEMPLATE_SRC=""
TMP_TEMPLATE=""
trap '[[ -n "${TMP_TEMPLATE:-}" ]] && rm -f "$TMP_TEMPLATE"' EXIT
HYSTERIA_BIN="${HYSTERIA_BIN:-/usr/local/bin/hysteria}"
SERVICE_NAME="${HYSTERIA_SERVICE:-hysteria-server}"
UNIT_DIR="${SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
MASQUERADE_DIR="${MASQUERADE_DIR:-/var/www/hysteria}"
LISTEN="${HYSTERIA_LISTEN:-:443}"
REG_API="${REG_API:-https://hysteria.ipx.sarl/new}"
# 节点鉴权地址：面板的 /auth（用户由 /join/{code} 注册）
AUTH_URL="${AUTH_URL:-https://hysteria.ipx.sarl/auth}"
BW_UP="${BW_UP:-100 mbps}"
BW_DOWN="${BW_DOWN:-100 mbps}"

REG_PAYLOAD_DEFAULT='{"ip":"__IP__","obfs_password":"__CODE__","traffic_port":__PORT__,"traffic_secret":"__SECRET__","cert_sha256":"__CERT_SHA256__","cert_pin_sha256":"__CERT_PIN__","config_version":__CONFIG_VERSION__}'
REG_PAYLOAD="${REG_PAYLOAD:-$REG_PAYLOAD_DEFAULT}"

CODE="${CODE:-}"
TRAFFIC_PORT=""
TRAFFIC_SECRET=""
DRY_RUN=0
DO_REGISTER=1
REGISTER_ONLY=0
VERIFY_ONLY=0
FORCE=0
GEN_CERT=0
NO_DOWNLOAD=0

# ------------------------------------------------------------------ 日志
c_reset=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
c_yel=$'\033[33m'; c_cyan=$'\033[36m'
if [[ ! -t 2 ]]; then c_reset=""; c_red=""; c_grn=""; c_yel=""; c_cyan=""; fi
# 正常信息统一走 stdout（单一流，避免面板/跳板机把 stdout、stderr 分开显示导致串行错位）
info() { printf '%s[INFO]%s %s\n' "$c_cyan" "$c_reset" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$c_grn"  "$c_reset" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$c_yel"  "$c_reset" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$c_red"  "$c_reset" "$*" >&2; exit 1; }

# 带超时的命令包装：统一 run_t <秒> <命令...>
run_t() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    warn "系统缺少 timeout，直接执行: $*"
    "$@"
  fi
}

usage() {
  awk 'NR>2 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

# ------------------------------------------------------------------ 参数
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--code)        CODE="${2:-}"; shift 2 ;;
    --code=*)         CODE="${1#*=}"; shift ;;
    --listen)         LISTEN="${2:-}"; shift 2 ;;
    --traffic-port)   TRAFFIC_PORT="${2:-}"; shift 2 ;;
    --secret)         TRAFFIC_SECRET="${2:-}"; shift 2 ;;
    --reg-url)        REG_API="${2:-}"; shift 2 ;;
    --version)        HYSTERIA_VERSION="${2:-}"; shift 2 ;;
    --no-register)    DO_REGISTER=0; shift ;;
    --register-only)  REGISTER_ONLY=1; shift ;;
    --verify-only)    VERIFY_ONLY=1; shift ;;
    --no-download)    NO_DOWNLOAD=1; shift ;;
    --force)          FORCE=1; shift ;;
    --gen-cert)       GEN_CERT=1; shift ;;
    --template-url)   TEMPLATE_URL="${2:-}"; shift 2 ;;
    --template-file)  TEMPLATE_FILE="${2:-}"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    -*)               die "未知参数: $1（-h 查看用法）" ;;
    *)                [[ -z "$CODE" ]] || die "多余的位置参数: $1（-h 查看用法）"; CODE="$1"; shift ;;
  esac
done

need_root() {
  [[ ${EUID} -eq 0 ]] || die "需要 root 权限运行（会写 ${HYSTERIA_ETC}、${UNIT_DIR}、启动 systemd 服务）"
}

# ------------------------------------------------------------ 值生成/校验
validate_code() {
  local c="$1"
  [[ -n "$c" ]] || die "运营商识别码不能为空（用法: ./install.sh <运营商识别码>）"
  [[ "$c" =~ ^[A-Za-z0-9._-]{4,64}$ ]] \
    || die "运营商识别码只能包含字母/数字/._-，长度 4-64：'$c'"
}

# ------------------------------------------------------------ 配置读取
cfg_obfs_password() {
  awk '/^obfs:/{f=1;next} f&&/^[ ]+password:/{v=$0;sub(/^[ ]+password:[ ]*/,"",v);gsub(/["\047]/,"",v);print v;exit}' "$1"
}
cfg_traffic_port() {
  awk '/^trafficStats:/{f=1;next} f&&/^[ ]+listen:/{v=$0;sub(/.*:/,"",v);gsub(/["\047]/,"",v);print v;exit}' "$1"
}
cfg_traffic_secret() {
  awk '/^trafficStats:/{f=1;next} f&&/^[ ]+secret:/{v=$0;sub(/^[ ]+secret:[ ]*/,"",v);gsub(/["\047]/,"",v);print v;exit}' "$1"
}

port_in_use() {
  local p="$1"
  ss -H -lntu 2>/dev/null | awk -v p=":$p" '$4 ~ p"$" {found=1} END{exit !found}'
}

pick_traffic_port() {
  local p tries=0
  while (( tries < 80 )); do
    p=$(( (RANDOM % 9001) + 10000 ))
    if ! port_in_use "$p"; then printf '%s' "$p"; return 0; fi
    tries=$((tries + 1))
  done
  die "在 10000-19000 范围内找不到空闲端口（试了 ${tries} 次）"
}

gen_secret() { openssl rand -hex 24; }

detect_public_ip() {
  local url ip
  for url in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip \
             https://checkip.amazonaws.com https://api64.ipify.org; do
    ip="$( { run_t 8 curl -fsS "$url" 2>/dev/null || true; } | tr -d '[:space:]')"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
  done
  return 1
}

# --------------------------------------------------------------- 渲染配置
# 按顶层块定位，只替换目标子键，块内其他内容/注释原样保留
render_config() {
  local tpl="$1" out="$2"
  local code="$3" port="$4" secret="$5" cert="$6" key="$7" masq="$8" up="$9" down="${10}" listen="${11}"

  awk -v code="$code" -v port="$port" -v secret="$secret" \
      -v cert="$cert" -v key="$key" -v masq="$masq" \
      -v up="$up" -v down="$down" -v listen="$listen" -v authurl="$AUTH_URL" '
    function q(v) { return "\047" v "\047" }
    {
      line = $0
      if (line ~ /^[A-Za-z_][A-Za-z0-9_]*:/) { top = line; sub(/:.*/, "", top) }
      ind = line; sub(/[^ ].*$/, "", ind)

      if (line ~ /^listen:/)                              { print "listen: " q(listen); next }
      if (top == "tls" && line ~ /^[ ]+cert:/)             { print ind "cert: " cert; next }
      if (top == "tls" && line ~ /^[ ]+key:/)              { print ind "key: " key; next }
      if (top == "obfs" && line ~ /^[ ]+password:/)        { print ind "password: " code; next }
      if (top == "trafficStats" && line ~ /^[ ]+listen:/)  { print ind "listen: " q("0.0.0.0:" port); next }
      if (top == "trafficStats" && line ~ /^[ ]+secret:/)  { print ind "secret: " secret; next }
      if (top == "auth" && line ~ /^[ ]+url:/)             { print ind "url: " q(authurl); next }
      if (top == "masquerade" && line ~ /^[ ]+dir:/)       { print ind "dir: " masq; next }
      if (top == "bandwidth" && line ~ /^[ ]+up:/)         { print ind "up: " q(up); next }
      if (top == "bandwidth" && line ~ /^[ ]+down:/)       { print ind "down: " q(down); next }
      print
    }
  ' "$tpl" > "$out"
}

# 回读校验：目标字段必须真的写进去了
verify_rendered() {
  local cfg="$1" code="$2" port="$3" secret="$4"
  grep -q "password: ${code}$" "$cfg" || die "渲染失败：obfs salamander password 未写入 ${cfg}"
  grep -q "secret: ${secret}$" "$cfg" || die "渲染失败：trafficStats secret 未写入 ${cfg}"
  grep -q "listen: '0.0.0.0:${port}'" "$cfg" || die "渲染失败：trafficStats listen 端口未写入 ${cfg}"
  grep -q "url: '${AUTH_URL}'" "$cfg" || die "渲染失败：auth.http.url 未写入 ${cfg}（期望 ${AUTH_URL}）"
  if grep -q '2664184394b93fae40dc25e5eb62f5043c01ca08ad5c95aa' "$cfg"; then
    die "渲染失败：模板里的示例 secret 仍在 ${cfg}"
  fi
  if grep -qE '^\[(OK|INFO|WARN|FAIL)\]' "$cfg"; then
    die "渲染失败：配置里混入了日志行（${cfg}）"
  fi
}

# ------------------------------------------------------------------ 证书
# 证书与私钥是否配对（不配对时 hysteria 启动即失败）
cert_key_match() {
  local cert="$1" key="$2" a b
  [[ -s "$cert" && -s "$key" ]] || return 1
  a="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl sha256)"
  b="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl sha256)"
  [[ -n "$a" && "$a" == "$b" ]]
}

# 证书指纹：
#   hex  — openssl 的 SHA256 Fingerprint（AB:CD:… 给人看，面板展示/核对）
#   pin  — base64(SHA256(DER 证书))，Hysteria 客户端 tls.pinSHA256 用这个
# 输出 "hex|pin"；失败返回非 0。
cert_fingerprints() {
  local cert="$1" hex pin
  [[ -s "$cert" ]] || return 1
  hex="$(openssl x509 -in "$cert" -noout -fingerprint -sha256 2>/dev/null | sed 's/^[^=]*=//')"
  pin="$(openssl x509 -in "$cert" -outform der 2>/dev/null | openssl dgst -sha256 -binary | base64 -w0 2>/dev/null || true)"
  [[ -n "$hex" && -n "$pin" ]] || return 1
  printf '%s|%s' "$hex" "$pin"
}

# 从面板拉标准模板：GET {TEMPLATE_URL} → 写出 content 到 $2，stdout 打印 version。
fetch_remote_template() {
  local url="$1" out="$2" json=""
  [[ -n "$url" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  json="$( { run_t 10 curl -sS -f "$url" 2>/dev/null || true; } )"
  [[ -n "$json" ]] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  printf '%s' "$json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
content = data.get("content") or ""
if not content:
    sys.exit(1)
open(sys.argv[1], "w").write(content if content.endswith("\n") else content + "\n")
print("%s\t%s" % (data.get("version") or 0, data.get("source") or "standard"))
' "$out"
}

# 自动生成两个文件：cert（证书）+ key（EC P-256 私钥），10 年有效期，
# SAN 含主机名、localhost、127.0.0.1 与探测到的公网 IP
gen_cert() {
  local cert="$1" key="$2" ip="${PUBLIC_IP:-}" host san
  host="$(hostname -f 2>/dev/null || hostname)"
  [[ -n "$host" ]] || host="localhost"
  san="DNS:${host},DNS:localhost,IP:127.0.0.1"
  if [[ -n "$ip" ]]; then san="${san},IP:${ip}"; fi

  mkdir -p "$(dirname "$cert")"
  info "→ 自动生成证书对（EC P-256，10 年）"
  info "  CN=${host}  SAN=${san}"
  run_t 60 openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$key" -out "$cert" -days 3650 -nodes \
    -subj "/CN=${host}" -addext "subjectAltName=${san}" >/dev/null 2>&1 \
    || die "生成证书失败（openssl req 出错）"
  chmod 644 "$cert"
  chmod 600 "$key"
}

install_cert() {
  local cert="$1" key="$2" ts
  mkdir -p "$(dirname "$cert")"

  if [[ $GEN_CERT -eq 1 ]]; then
    if [[ -s "$cert" || -s "$key" ]]; then
      ts="$(date +%Y%m%d%H%M%S)"
      [[ -s "$cert" ]] && cp -a "$cert" "${cert}.bak.${ts}"
      [[ -s "$key" ]]  && cp -a "$key"  "${key}.bak.${ts}"
      info "→ 已备份旧证书：${cert}.bak.${ts}"
    fi
    gen_cert "$cert" "$key"
  elif [[ -s "${SCRIPT_DIR}/cert" && -s "${SCRIPT_DIR}/key" ]]; then
    info "→ 使用脚本目录自带的 cert/key"
    install -m 644 "${SCRIPT_DIR}/cert" "$cert"
    install -m 600 "${SCRIPT_DIR}/key"  "$key"
  elif cert_key_match "$cert" "$key"; then
    info "→ 复用已存在的证书 $cert"
    chmod 600 "$key"
  else
    if [[ -s "$cert" || -s "$key" ]]; then
      warn "已有证书/私钥缺失或不匹配，重新生成"
    fi
    gen_cert "$cert" "$key"
  fi

  cert_key_match "$cert" "$key" || die "证书与私钥不匹配：$cert / $key"
  ok "证书就绪：$cert（有效期至 $(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)）"
  ok "私钥权限：$(stat -c '%a %n' "$key" 2>/dev/null || ls -l "$key")"
}

# ------------------------------------------------------------ 二进制/服务
arch_name() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv6l) echo arm ;;
    i386|i686)     echo 386 ;;
    *) die "不支持的 CPU 架构: $(uname -m)" ;;
  esac
}

installed_version() {
  "$HYSTERIA_BIN" version 2>/dev/null | awk -F'\t' '/^Version:/ {print $2; exit}'
}

install_binary() {
  mkdir -p "$(dirname "$HYSTERIA_BIN")"
  if [[ -x "$HYSTERIA_BIN" ]]; then
    local cur
    cur="$(installed_version || true)"
    if [[ "$cur" == "$HYSTERIA_VERSION" && $FORCE -eq 0 ]]; then
      ok "已安装 hysteria ${cur}，跳过下载"
      return 0
    fi
    info "→ 现有 hysteria ${cur:-未知}，目标 ${HYSTERIA_VERSION}，重新安装"
  fi

  if [[ $NO_DOWNLOAD -eq 1 ]]; then
    [[ -x "$HYSTERIA_BIN" ]] || die "--no-download 但 ${HYSTERIA_BIN} 不存在或不可执行"
    return 0
  fi

  local arch url tmp
  arch="$(arch_name)"
  url="https://github.com/HyNetworks/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-${arch}"
  tmp="$(mktemp -d)"
  info "→ 下载 hysteria ${HYSTERIA_VERSION} (${arch})"
  run_t 300 curl -fL --retry 3 --connect-timeout 10 --no-progress-meter "$url" -o "$tmp/hysteria" \
    || { rm -rf "$tmp"; die "下载失败: $url（可用 HYSTERIA_VERSION=vX.Y.Z 换版本，或 --no-download 手动放置二进制）"; }
  [[ -s "$tmp/hysteria" ]] || { rm -rf "$tmp"; die "下载到的文件为空: $url"; }
  install -m 755 "$tmp/hysteria" "$HYSTERIA_BIN"
  BINARY_CHANGED=1
  rm -rf "$tmp"
  ok "已安装 $("$HYSTERIA_BIN" version 2>/dev/null | awk -F'\t' '/^Version:/ {print $2; exit}') → $HYSTERIA_BIN"
}

install_unit() {
  local unit="${UNIT_DIR}/${SERVICE_NAME}.service" tmp
  mkdir -p "$UNIT_DIR"
  tmp="${unit}.tmp.$$"
  cat > "$tmp" <<EOF
[Unit]
Description=Hysteria2 Server
Documentation=https://v2.hysteria.network/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${HYSTERIA_BIN} server -c ${CONFIG}
WorkingDirectory=${HYSTERIA_ETC}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$tmp"
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$tmp" >/dev/null 2>&1 || warn "systemd-analyze verify 报警（$unit），继续"
  fi
  if [[ -f "$unit" ]] && cmp -s "$tmp" "$unit"; then
    rm -f "$tmp"
    ok "systemd 单元未变化：$unit"
  else
    install -m 644 "$tmp" "$unit"
    rm -f "$tmp"
    UNIT_CHANGED=1
    ok "systemd 单元已写入：$unit"
  fi
  systemctl daemon-reload
}

# 配置写完/二进制或单元更新后，立刻重启让新状态生效（三者都没变才跳过重启）
apply_service() {
  local cfg_changed="${1:-1}" reason=""
  systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || warn "enable ${SERVICE_NAME} 失败"

  if [[ "$cfg_changed" -eq 1 ]]; then reason="${reason}配置变更 "; fi
  if [[ ${BINARY_CHANGED:-0} -eq 1 ]]; then reason="${reason}二进制更新 "; fi
  if [[ ${UNIT_CHANGED:-0} -eq 1 ]]; then reason="${reason}systemd 单元变更 "; fi

  if [[ -n "$reason" ]]; then
    info "→ 重启 ${SERVICE_NAME}（${reason% }）"
    systemctl restart "$SERVICE_NAME" || die "重启失败，看日志：journalctl -u ${SERVICE_NAME} -n 30 --no-pager"
  elif systemctl is-active --quiet "$SERVICE_NAME"; then
    ok "${SERVICE_NAME} 已在运行，配置未变更，跳过重启"
    return 0
  else
    info "→ 启动 ${SERVICE_NAME}"
    systemctl start "$SERVICE_NAME" || die "启动失败，看日志：journalctl -u ${SERVICE_NAME} -n 30 --no-pager"
  fi

  local i
  for i in $(seq 1 20); do
    if systemctl is-active --quiet "$SERVICE_NAME"; then ok "${SERVICE_NAME} 已 active"; return 0; fi
    sleep 1
  done
  journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
  die "${SERVICE_NAME} 未能进入 active 状态"
}

# ------------------------------------------------------------------ 验证
listen_port() {
  local addr="$1"
  printf '%s' "${addr##*:}"
}

verify_service() {
  local port="$1" api_port="$2" secret="$3"
  local sport; sport="$(listen_port "$LISTEN")"

  ok "— 验证开始 —"
  systemctl is-active --quiet "$SERVICE_NAME" && ok "服务状态: active" || die "服务不是 active"

  local ss_out
  ss_out="$(ss -lunp 2>/dev/null | awk -v p=":${sport}" '$4 ~ p"$"')"
  [[ -n "$ss_out" ]] || die "UDP ${sport} 端口没有在听（排查: journalctl -u ${SERVICE_NAME} -n 30 --no-pager）"
  ok "UDP ${sport} 正在监听: $(printf '%s' "$ss_out" | awk '{print $4}' | head -1)"

  local code body i
  for i in 1 2 3 4 5; do
    code="$( { run_t 5 curl -sS -o /tmp/hy_api_body.$$ -w '%{http_code}' \
      -H "Authorization: ${secret}" "http://127.0.0.1:${api_port}/traffic" || true; } )"
    [[ -n "$code" ]] || code="000"
    [[ "$code" == "200" ]] && break
    sleep 1
  done
  body="$(head -c 120 /tmp/hy_api_body.$$ 2>/dev/null || true)"
  rm -f /tmp/hy_api_body.$$
  [[ -n "$body" ]] || body='{}'
  if [[ "$code" == "200" ]]; then
    ok "trafficStats API 200 → http://127.0.0.1:${api_port}/traffic  响应: ${body}"
  else
    warn "trafficStats API 返回 ${code} → http://127.0.0.1:${api_port}/traffic  响应: ${body}"
    warn "  401/403=secret 不匹配，404=路径不对，000=端口没起来/监听地址不对"
  fi
}

# ------------------------------------------------------------------ 上报
build_payload() {
  local ip="$1" code="$2" port="$3" secret="$4" cert_sha="$5" cert_pin="$6" cfgver="$7" tpl="$8"
  printf '%s' "$tpl" \
    | sed -e "s|__IP__|${ip}|g" -e "s|__CODE__|${code}|g" \
          -e "s|__PORT__|${port}|g" -e "s|__SECRET__|${secret}|g" \
          -e "s|__CERT_SHA256__|${cert_sha}|g" -e "s|__CERT_PIN__|${cert_pin}|g" \
          -e "s|__CONFIG_VERSION__|${cfgver}|g"
}

register_node() {
  local cfg="${1:-$CONFIG}"
  local code port secret ip payload http
  code="$(cfg_obfs_password "$cfg")"
  port="$(cfg_traffic_port "$cfg")"
  secret="$(cfg_traffic_secret "$cfg")"
  [[ -n "$code" && -n "$port" && -n "$secret" ]] \
    || die "无法从 $cfg 读出 obfs.password / trafficStats.listen / trafficStats.secret"

  ip="${PUBLIC_IP:-}"
  if [[ -z "$ip" ]]; then
    ip="$(detect_public_ip || true)"
    [[ -n "$ip" ]] || die "探测不到公网 IP（可用 PUBLIC_IP=1.2.3.4 指定）"
  fi

  local cert_path="${HYSTERIA_ETC}/cert.pem" cert_sha="" cert_pin="" fp=""
  if fp="$(cert_fingerprints "$cert_path")"; then
    cert_sha="${fp%%|*}"
    cert_pin="${fp##*|}"
  else
    warn "读不到证书指纹（${cert_path}），本次上报不含 cert_sha256 / cert_pin_sha256"
  fi

  local cfg_version="0"
  if [[ -f "${HYSTERIA_ETC}/config.template.version" ]]; then
    cfg_version="$(tr -dc '0-9' < "${HYSTERIA_ETC}/config.template.version" 2>/dev/null || true)"
    [[ -n "$cfg_version" ]] || cfg_version="0"
  fi

  payload="$(build_payload "$ip" "$code" "$port" "$secret" "$cert_sha" "$cert_pin" "$cfg_version" "$REG_PAYLOAD")"
  mkdir -p "$HYSTERIA_ETC"
  printf '%s\n' "$payload" > "${HYSTERIA_ETC}/register.json"

  info "→ 上报注册信息到 ${REG_API}"
  info "  payload: ${payload}"

  local attempt body_file code_http
  for attempt in 1 2 3; do
    body_file="$(mktemp)"
    code_http="$( { run_t 20 curl -sS -o "$body_file" -w '%{http_code}' -X POST "$REG_API" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      --data-binary "$payload" 2>/dev/null || true; } )"
    [[ -n "$code_http" ]] || code_http="000"
    if [[ "$code_http" =~ ^2[0-9][0-9]$ ]]; then
      ok "注册成功（HTTP ${code_http}）响应: $(head -c 200 "$body_file")"
      rm -f "$body_file"
      return 0
    fi
    warn "注册第 ${attempt}/3 次失败：HTTP ${code_http} 响应: $(head -c 200 "$body_file")"
    rm -f "$body_file"
    if [[ "$code_http" == "000" ]]; then
      warn "  000 = DNS 解析失败 / 连不上 / 超时（${REG_API}）"
    fi
    sleep 5
  done

  printf '%s\n' "$payload" > "${HYSTERIA_ETC}/register.json"
  warn "注册失败，payload 已保存：${HYSTERIA_ETC}/register.json"
  warn "手动重试：curl -X POST ${REG_API} -H 'Content-Type: application/json' --data-binary @${HYSTERIA_ETC}/register.json"
  warn "或服务装好后运行：./install.sh --register-only"
  return 1
}

# 读取运营商识别码：不用 read -p（终端对中文宽字符宽度算错时会把提示和输入挤到上一行、
# 输入内容看不见），改成先单独打印提示行，再用普通 read 读一行；stdin 是管道时也能喂值。
# 注意：提示必须写终端（/dev/tty 或 stderr），否则经命令替换调用时会被当成返回值捕获。
read_code() {
  local ans="" dst="/dev/stderr"
  if { true >/dev/tty; } 2>/dev/null; then dst="/dev/tty"; fi
  { printf '请输入运营商识别码（字母/数字/._-，回车确认）：\n'; printf '> '; } > "$dst"
  IFS= read -r ans || true
  printf '\n' > "$dst"
  CODE="$(printf '%s' "$ans" | tr -d '[:space:]')"
}
main() {
  # --verify-only：只读检查，不改任何东西
  if [[ $VERIFY_ONLY -eq 1 ]]; then
    [[ -s "$CONFIG" ]] || die "找不到配置 $CONFIG"
    local tp ts
    tp="$(cfg_traffic_port "$CONFIG")"
    ts="$(cfg_traffic_secret "$CONFIG")"
    PUBLIC_IP="${PUBLIC_IP:-$(detect_public_ip || true)}"
    info "公网 IP: ${PUBLIC_IP:-（探测失败）}"
    verify_service "$(listen_port "$LISTEN")" "$tp" "$ts"
    exit 0
  fi

  # --register-only：服务已装好，只从现有配置重新上报（无需再给识别码）
  if [[ $REGISTER_ONLY -eq 1 ]]; then
    [[ -s "$CONFIG" ]] || die "找不到配置 $CONFIG（先跑一次完整安装）"
    need_root
    command -v curl >/dev/null 2>&1 || die "缺少依赖命令: curl"
    register_node "$CONFIG" || exit 1
    exit 0
  fi

  # 运营商识别码：位置参数 > --code > 环境变量 CODE > 交互读取
  if [[ -z "$CODE" ]]; then
    read_code
  fi
  if [[ -z "$CODE" ]]; then
    usage >&2
    die "缺少运营商识别码（非交互环境请用: ./install.sh --code <CODE>）"
  fi
  validate_code "$CODE"
  info "运营商识别码: ${CODE}"

  need_root
  for t in curl openssl awk sed ss; do
    command -v "$t" >/dev/null 2>&1 || die "缺少依赖命令: $t"
  done

  # 公网 IP（证书 SAN 与上报都用它）
  if [[ -z "${PUBLIC_IP:-}" ]]; then
    info "→ 探测公网 IP"
    PUBLIC_IP="$(detect_public_ip || true)"
  fi
  if [[ -n "${PUBLIC_IP:-}" ]]; then ok "公网 IP: $PUBLIC_IP"; else warn "公网 IP 探测失败（可用 PUBLIC_IP=1.2.3.4 指定）"; fi

  # 端口与 secret：命令行 > 已有配置（复用）> 随机生成
  if [[ -f "$CONFIG" ]]; then
    if [[ -z "$TRAFFIC_PORT" ]]; then
      TRAFFIC_PORT="$(cfg_traffic_port "$CONFIG")"
      # 旧配置里的端口可能不在 10000-19000 区间（例如历史模板的 8080），超出就重新随机
      if [[ -n "$TRAFFIC_PORT" ]] && ! [[ "$TRAFFIC_PORT" =~ ^[0-9]+$ && "$TRAFFIC_PORT" -ge 10000 && "$TRAFFIC_PORT" -le 19000 ]]; then
        info "→ 旧端口 $TRAFFIC_PORT 不在 10000-19000，重新随机"
        TRAFFIC_PORT=""
      fi
      if [[ -n "$TRAFFIC_PORT" ]]; then info "→ 复用现有 trafficStats 端口: $TRAFFIC_PORT"; fi
    fi
    if [[ -z "$TRAFFIC_SECRET" ]]; then
      TRAFFIC_SECRET="$(cfg_traffic_secret "$CONFIG")"
      if [[ -n "$TRAFFIC_SECRET" ]]; then info "→ 复用现有 trafficStats secret"; fi
    fi
  fi
  if [[ -z "$TRAFFIC_PORT" ]]; then
    TRAFFIC_PORT="$(pick_traffic_port)"
    info "→ trafficStats 端口随机: $TRAFFIC_PORT"
  else
    [[ "$TRAFFIC_PORT" =~ ^[0-9]+$ ]] || die "--traffic-port 必须是数字"
    port_in_use "$TRAFFIC_PORT" && die "端口 $TRAFFIC_PORT 已被占用"
  fi
  if [[ -z "$TRAFFIC_SECRET" ]]; then
    TRAFFIC_SECRET="$(gen_secret)"
    info "→ trafficStats secret 随机生成（48 hex）"
  fi

  local cert="${HYSTERIA_ETC}/cert.pem" key="${HYSTERIA_ETC}/key.pem"

  # 标准模板：只从面板拉（仓库里不再放 config.yaml.example）
  local template_version="" template_source="standard" fetched=""
  if [[ -n "$TEMPLATE_FILE" ]]; then
    [[ -s "$TEMPLATE_FILE" ]] || die "TEMPLATE_FILE 不存在或为空：${TEMPLATE_FILE}"
    TEMPLATE_SRC="$TEMPLATE_FILE"
    info "使用本地模板文件：${TEMPLATE_FILE}"
    template_version="$(tr -dc '0-9' < "${HYSTERIA_ETC}/config.template.version" 2>/dev/null || true)"
    [[ -n "$template_version" ]] || template_version="0"
  else
    [[ -n "$TEMPLATE_URL" ]] || die "TEMPLATE_URL 为空：标准模板只能从面板拉取（或用 --template-file 指定本地文件）"
    TMP_TEMPLATE="$(mktemp)"
    local tpl_url="$TEMPLATE_URL"
    if [[ "$tpl_url" != *"?"* ]]; then
      tpl_url="${tpl_url}?code=${CODE}"
    fi
    info "→ 拉取配置模板：${tpl_url}"
    if ! fetched="$(fetch_remote_template "$tpl_url" "$TMP_TEMPLATE")" || [[ ! -s "$TMP_TEMPLATE" ]]; then
      die "拉取配置模板失败：${tpl_url}（面板不可达或接口 404，需面板版本包含 GET /api/config-template）"
    fi
    TEMPLATE_SRC="$TMP_TEMPLATE"
    template_version="${fetched%%$'\t'*}"
    template_source="${fetched##*$'\t'}"
    [[ "$template_source" == "$fetched" ]] && template_source="standard"
    local source_label="平台标准"
    [[ "$template_source" == "provider" ]] && source_label="服务商自定义"
    ok "已获取${source_label}模板 v${template_version}（$(wc -c < "$TMP_TEMPLATE" | tr -d ' ') 字节）"
  fi

  # dry-run：只渲染到 stdout
  if [[ $DRY_RUN -eq 1 ]]; then
    info "→ [dry-run] 渲染配置："
    render_config "$TEMPLATE_SRC" /dev/stdout "$CODE" "$TRAFFIC_PORT" "$TRAFFIC_SECRET" \
      "$cert" "$key" "$MASQUERADE_DIR" "$BW_UP" "$BW_DOWN" "$LISTEN"
    local ip="${PUBLIC_IP:-<公网IP>}"
    info "→ [dry-run] 上报 ${REG_API}："
    build_payload "$ip" "$CODE" "$TRAFFIC_PORT" "$TRAFFIC_SECRET" "<证书SHA256>" "<证书PIN>" "${template_version:-0}" "$REG_PAYLOAD"
    printf '\n'
    info "[dry-run] 未改动任何文件"
    exit 0
  fi

  # 目录/模板：版本 + 实际使用的那份模板留档，便于排查
  mkdir -p "$HYSTERIA_ETC"
  printf '%s\n' "${template_version:-0}" > "${HYSTERIA_ETC}/config.template.version"
  install -m 644 "$TEMPLATE_SRC" "${HYSTERIA_ETC}/config.yaml.template"

  # 证书
  install_cert "$cert" "$key"
  if fp="$(cert_fingerprints "$cert")"; then
    ok "证书 SHA256: ${fp%%|*}"
    info "  客户端 pinSHA256: ${fp##*|}"
  fi

  # masquerade 目录
  mkdir -p "$MASQUERADE_DIR"
  if [[ ! -f "${MASQUERADE_DIR}/index.html" ]]; then
    cat > "${MASQUERADE_DIR}/index.html" <<'HTML'
<!doctype html><html><head><meta charset="utf-8"><title>Welcome</title></head>
<body><h1>It works!</h1></body></html>
HTML
  fi
  chmod 755 "$MASQUERADE_DIR"

  # 二进制 + systemd 单元先就位（随后配置写完一次性重启，让新二进制和配置同时生效）
  install_binary
  install_unit

  # 渲染配置（旧配置先备份），写完立刻重启服务
  local bak="" cfg_changed=1
  if [[ -f "$CONFIG" ]]; then
    bak="${CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$CONFIG" "$bak"
    info "→ 已备份旧配置：$bak"
  fi
  render_config "$TEMPLATE_SRC" "$CONFIG" "$CODE" "$TRAFFIC_PORT" "$TRAFFIC_SECRET" \
    "$cert" "$key" "$MASQUERADE_DIR" "$BW_UP" "$BW_DOWN" "$LISTEN"
  chmod 600 "$CONFIG"
  verify_rendered "$CONFIG" "$CODE" "$TRAFFIC_PORT" "$TRAFFIC_SECRET"
  if [[ -n "$bak" ]] && cmp -s "$bak" "$CONFIG"; then
    cfg_changed=0
    ok "配置内容与备份一致（sha256 $(sha256sum "$CONFIG" | cut -d' ' -f1)），无需重启"
  else
    ok "配置已生成：$CONFIG（sha256 $(sha256sum "$CONFIG" | cut -d' ' -f1)）"
  fi

  # 配置写完后立刻重启，让改变生效
  apply_service "$cfg_changed"

  # 验证通过才上报
  verify_service "$(listen_port "$LISTEN")" "$TRAFFIC_PORT" "$TRAFFIC_SECRET"

  local reg_status="跳过（--no-register）"
  if [[ $DO_REGISTER -eq 1 ]]; then
    if register_node "$CONFIG"; then reg_status="成功"; else reg_status="失败（payload 已保存，见上方命令）"; fi
  fi

  # 摘要
  echo
  printf '%s================ 安装摘要 ================%s\n' "$c_cyan" "$c_reset"
  cat <<EOF
配置文件      : ${CONFIG}
监听          : ${LISTEN} (UDP)
运营商识别码  : ${CODE}          # = obfs salamander password，客户端需一致
trafficStats  : 0.0.0.0:${TRAFFIC_PORT}/traffic（本机探活 http://127.0.0.1:${TRAFFIC_PORT}/traffic）
traffic secret: ${TRAFFIC_SECRET}
证书 / 私钥   : ${cert} / ${key}
公网 IP       : ${PUBLIC_IP:-未知}
服务          : ${SERVICE_NAME}（$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo unknown)）
注册上报      : ${REG_API} → ${reg_status}
EOF
  echo
  warn "记得放行防火墙 UDP $(listen_port "$LISTEN")（云厂商安全组 + 本机 iptables/nftables）"
  warn "trafficStats 监听 0.0.0.0:${TRAFFIC_PORT}，需要放行 TCP ${TRAFFIC_PORT}（靠 secret 头鉴权）"
  info "日志：journalctl -u ${SERVICE_NAME} -f --no-pager"
}

main "$@"
