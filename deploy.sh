#!/usr/bin/env bash
# =============================================================================
#  sui-deploy — 在一台空服务器上一键部署 s-ui（sing-box 面板）全套节点
#
#  用法（root）：
#    bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/<仓库名>/main/deploy.sh) 你的域名
#
#  可选参数：
#    --email you@example.com      证书通知邮箱（默认 admin@域名）
#    --version v1.6.7             指定 s-ui 版本（默认用下面的 SUI_VERSION）
#    --reality-target host        Reality 借用的网站（默认 swdist.apple.com）
#    --skip-dns-check             跳过“域名是否解析到本机”的检查
#    --force                      已装过 s-ui 也继续（会重置面板账号/端口，并新增一套节点）
#
#  部署内容：
#    s-ui 面板 + 订阅（HTTPS，Let's Encrypt 证书，acme.sh 自动续期）
#    节点：VLESS-Reality-Vision / Hysteria2 / TUIC v5 / Trojan / VMess
# =============================================================================
set -euo pipefail

# 由 GitHub Actions 自动更新为官方最新版本，请勿改动这一行的格式
SUI_VERSION="v1.6.8"

REALITY_TARGET="swdist.apple.com"
MASQUERADE_URL="https://www.apple.com"
DOMAIN=""; EMAIL=""; SKIP_DNS=0; FORCE=0

red(){ echo -e "\033[31m$*\033[0m"; }; grn(){ echo -e "\033[32m$*\033[0m"; }
ylw(){ echo -e "\033[33m$*\033[0m"; }; step(){ echo; echo -e "\033[36m==> $*\033[0m"; }
die(){ red "错误：$*"; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --email) EMAIL="$2"; shift 2 ;;
    --version) SUI_VERSION="$2"; shift 2 ;;
    --reality-target) REALITY_TARGET="$2"; shift 2 ;;
    --skip-dns-check) SKIP_DNS=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" 2>/dev/null || true; exit 0 ;;
    -*) die "未知参数 $1" ;;
    *) DOMAIN="$1"; shift ;;
  esac
done

[ -n "$DOMAIN" ] || die "请提供域名，例如：bash deploy.sh node.example.com"
[[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] || die "域名格式不正确：$DOMAIN"
DOMAIN="$(echo "$DOMAIN" | tr 'A-Z' 'a-z')"
[ -n "$EMAIL" ] || EMAIL="admin@${DOMAIN}"
[[ "$SUI_VERSION" == v* ]] || SUI_VERSION="v${SUI_VERSION}"

# ---------------------------------------------------------------- 环境检查
step "检查运行环境"
[ "$(id -u)" = 0 ] || die "请用 root 运行"
[ -d /run/systemd/system ] || die "需要 systemd"
command -v apt-get >/dev/null || die "目前只支持 Debian / Ubuntu"
if [ -e /usr/local/s-ui/sui ] && [ $FORCE = 0 ]; then
  die "检测到已安装 s-ui。这个脚本面向空服务器；确实要覆盖请加 --force"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget tar socat cron openssl python3 ca-certificates iproute2 >/dev/null
systemctl enable --now cron >/dev/null 2>&1 || true

PUBIP="$(curl -4 -fsS --max-time 8 https://api.ipify.org || curl -4 -fsS --max-time 8 https://ifconfig.me || true)"
DNSIP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}')"
grn "本机公网 IP：${PUBIP:-未知}    $DOMAIN 解析到：${DNSIP:-未解析}"
if [ $SKIP_DNS = 0 ]; then
  [ -n "$DNSIP" ] || die "$DOMAIN 还没有解析。请先添加 A 记录指向 ${PUBIP:-本机 IP}（Cloudflare 请用“仅 DNS”灰云）"
  [ "$DNSIP" = "$PUBIP" ] || die "$DOMAIN 解析到 $DNSIP，不是本机 $PUBIP。若用 Cloudflare 请关闭代理（灰云）"
fi
if ss -ltnH 'sport = :80' | grep -q .; then
  die "80 端口被占用（$(ss -ltnpH 'sport = :80' | grep -o 'users:.*' | head -1)）。申请证书需要 80 端口空闲"
fi

# ---------------------------------------------------------------- 工具函数
rand_str(){ head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "$1"; }
USED_PORTS=" "
rand_port(){
  local p
  while :; do
    p=$(( 20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000 ))
    [[ "$USED_PORTS" == *" $p "* ]] && continue
    ss -tulnH "sport = :$p" | grep -q . && continue
    USED_PORTS="$USED_PORTS$p "; echo "$p"; return
  done
}

# ---------------------------------------------------------------- 系统优化
step "开启 BBR"
cat > /etc/sysctl.d/99-sui-deploy.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sysctl --system >/dev/null 2>&1 || true
grn "拥塞控制：$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 未知)"

# ---------------------------------------------------------------- 证书
step "申请 Let's Encrypt 证书（acme.sh，自动续期）"
ACME=/root/.acme.sh/acme.sh
if [ ! -x "$ACME" ]; then
  curl -fsSL https://get.acme.sh | sh -s email="$EMAIL" >/dev/null
fi
"$ACME" --upgrade --auto-upgrade >/dev/null 2>&1 || true
"$ACME" --set-default-ca --server letsencrypt >/dev/null
rc=0
"$ACME" --issue -d "$DOMAIN" --standalone --keylength ec-256 --server letsencrypt || rc=$?
[ $rc = 0 ] || [ $rc = 2 ] || die "证书申请失败（检查域名解析、80 端口是否被云厂商安全组拦截）"
CERT_DIR="/root/cert/${DOMAIN}"
mkdir -p "$CERT_DIR"
"$ACME" --install-cert -d "$DOMAIN" --ecc \
  --fullchain-file "$CERT_DIR/fullchain.pem" \
  --key-file "$CERT_DIR/privkey.pem" \
  --reloadcmd "systemctl restart s-ui >/dev/null 2>&1 || true" >/dev/null
CERT="$CERT_DIR/fullchain.pem"; KEY="$CERT_DIR/privkey.pem"
openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null || die "证书无效"
grn "证书：$CERT（到期 $(openssl x509 -in "$CERT" -noout -enddate | cut -d= -f2)）"
grn "续期：acme.sh 定时任务每天检查，到期前 30 天自动续签并重启 s-ui"

# ---------------------------------------------------------------- 安装 s-ui
step "安装 s-ui ${SUI_VERSION}（官方安装脚本，含 SHA256 校验）"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT
curl -fsSL "https://raw.githubusercontent.com/alireza0/s-ui/${SUI_VERSION}/install.sh" -o "$TMPD/install.sh" \
  || die "下载官方安装脚本失败（版本 ${SUI_VERSION} 是否存在？）"
printf 'n\n' | SUI_LANG=zhcn bash "$TMPD/install.sh" "$SUI_VERSION" >"$TMPD/install.log" 2>&1 \
  || { tail -20 "$TMPD/install.log"; die "s-ui 安装失败"; }
/usr/local/s-ui/sui -v || die "s-ui 安装异常"

ADMIN_USER="admin$(rand_str 5)"; ADMIN_PASS="$(rand_str 20)"
PANEL_PORT=$(rand_port); SUB_PORT=$(rand_port)
PANEL_PATH="/$(rand_str 10)/"; SUB_PATH="/$(rand_str 10)/"
P_VLESS=$(rand_port); P_HY2=$(rand_port); P_TUIC=$(rand_port); P_TROJAN=$(rand_port); P_VMESS=$(rand_port)
CLIENT_NAME="$(echo "${DOMAIN%%.*}" | tr -dc 'a-z0-9-')-$(rand_str 6)"

systemctl stop s-ui
/usr/local/s-ui/sui admin -username "$ADMIN_USER" -password "$ADMIN_PASS" >/dev/null
/usr/local/s-ui/sui setting -port "$PANEL_PORT" -path "$PANEL_PATH" -subPort "$SUB_PORT" -subPath "$SUB_PATH" >/dev/null
systemctl start s-ui
for _ in $(seq 1 30); do ss -ltnH "sport = :$PANEL_PORT" | grep -q . && break; sleep 1; done
ss -ltnH "sport = :$PANEL_PORT" | grep -q . || die "面板没有启动，查看日志：journalctl -u s-ui -n 50"

# ---------------------------------------------------------------- 创建节点
step "通过 s-ui API 创建 TLS 配置、用户和节点"
export DOMAIN CERT KEY REALITY_TARGET MASQUERADE_URL ADMIN_USER ADMIN_PASS PANEL_PORT PANEL_PATH \
       CLIENT_NAME P_VLESS P_HY2 P_TUIC P_TROJAN P_VMESS
python3 -I - <<'PY'
import json, os, secrets, sys, uuid, urllib.request, urllib.parse, http.cookiejar
E = os.environ
D = E['DOMAIN']
BASE = f"http://127.0.0.1:{E['PANEL_PORT']}{E['PANEL_PATH']}api/"
jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
# Host 头用域名：s-ui 用它生成订阅链接里的服务器地址
HDR = {'Host': f"{D}:{E['PANEL_PORT']}", 'X-Requested-With': 'XMLHttpRequest'}

def call(path, form=None):
    data = urllib.parse.urlencode(form).encode() if form is not None else None
    req = urllib.request.Request(BASE + path, data=data, headers=HDR)
    r = json.load(op.open(req, timeout=30))
    if not r.get('success'):
        sys.exit(f"API {path} 失败：{r.get('msg')}")
    return r.get('obj')

def save(obj, act, data, init=''):
    call('save', {'object': obj, 'action': act, 'data': json.dumps(data), 'initUsers': init})
    print(f"  ✓ {obj}: {data.get('name') or data.get('tag')}")

call('login', {'user': E['ADMIN_USER'], 'pass': E['ADMIN_PASS']})

# 1. TLS 配置
kp = {x.split(':')[0].strip(): x.split(':', 1)[1].strip() for x in call('keypairs?k=reality')}
sid = secrets.token_hex(4)
T = E['REALITY_TARGET']
save('tls', 'new', {'name': 'TCP-TLS', 'client': {},
     'server': {'enabled': True, 'server_name': D, 'alpn': ['h2', 'http/1.1'],
                'certificate_path': E['CERT'], 'key_path': E['KEY']}})
save('tls', 'new', {'name': 'QUIC-H3', 'client': {},
     'server': {'enabled': True, 'server_name': D, 'alpn': ['h3'],
                'certificate_path': E['CERT'], 'key_path': E['KEY']}})
save('tls', 'new', {'name': 'REALITY',
     'server': {'enabled': True, 'server_name': T,
                'reality': {'enabled': True, 'handshake': {'server': T, 'server_port': 443},
                            'private_key': kp['PrivateKey'], 'short_id': [sid]}},
     'client': {'reality': {'public_key': kp['PublicKey'], 'short_id': sid},
                'utls': {'enabled': True, 'fingerprint': 'chrome'}}})
tls = {t['name']: t['id'] for t in call('tls')['tls']}

# 2. 用户（订阅名 = 用户名）
n = E['CLIENT_NAME']
cfg = {
    'vless': {'name': n, 'uuid': str(uuid.uuid4()), 'flow': 'xtls-rprx-vision'},
    'vmess': {'name': n, 'uuid': str(uuid.uuid4()), 'alterId': 0},
    'trojan': {'name': n, 'password': secrets.token_urlsafe(16)},
    'hysteria2': {'name': n, 'password': secrets.token_urlsafe(16)},
    'tuic': {'name': n, 'uuid': str(uuid.uuid4()), 'password': secrets.token_urlsafe(16)},
}
save('clients', 'new', {'enable': True, 'name': n, 'config': cfg, 'inbounds': [], 'links': [],
                        'volume': 0, 'expiry': 0, 'desc': 'sui-deploy', 'group': ''})
cid = [c['id'] for c in call('clients')['clients'] if c['name'] == n][0]

# 3. 节点
P = lambda k: int(E[k])
inbounds = [
    {'type': 'vless', 'tag': f"vless-reality-{P('P_VLESS')}", 'listen': '::', 'listen_port': P('P_VLESS'),
     'tls_id': tls['REALITY']},
    {'type': 'hysteria2', 'tag': f"hy2-{P('P_HY2')}", 'listen': '::', 'listen_port': P('P_HY2'),
     'tls_id': tls['QUIC-H3'],
     'masquerade': {'type': 'proxy', 'url': E['MASQUERADE_URL'], 'rewrite_host': True}},
    {'type': 'tuic', 'tag': f"tuic-{P('P_TUIC')}", 'listen': '::', 'listen_port': P('P_TUIC'),
     'tls_id': tls['QUIC-H3'], 'congestion_control': 'bbr', 'auth_timeout': '3s',
     'heartbeat': '10s', 'zero_rtt_handshake': False},
    {'type': 'trojan', 'tag': f"trojan-{P('P_TROJAN')}", 'listen': '::', 'listen_port': P('P_TROJAN'),
     'tls_id': tls['TCP-TLS']},
    {'type': 'vmess', 'tag': f"vmess-{P('P_VMESS')}", 'listen': '::', 'listen_port': P('P_VMESS'),
     'tls_id': tls['TCP-TLS']},
]
for ib in inbounds:
    save('inbounds', 'new', ib, str(cid))

# 4. 面板 / 订阅启用 HTTPS（重启后生效）
call('save', {'object': 'settings', 'action': 'set', 'data': json.dumps({
    'webCertFile': E['CERT'], 'webKeyFile': E['KEY'], 'webDomain': D,
    'subCertFile': E['CERT'], 'subKeyFile': E['KEY'], 'subDomain': D})})
print('  ✓ 面板与订阅已切换为 HTTPS')
PY
systemctl restart s-ui
for _ in $(seq 1 30); do ss -ltnH "sport = :$SUB_PORT" | grep -q . && break; sleep 1; done
sleep 3

# ---------------------------------------------------------------- 防火墙
step "放行端口"
TCP_PORTS="80 $PANEL_PORT $SUB_PORT $P_VLESS $P_TROJAN $P_VMESS"; UDP_PORTS="$P_HY2 $P_TUIC"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  for p in $TCP_PORTS; do ufw allow "$p/tcp" >/dev/null; done
  for p in $UDP_PORTS; do ufw allow "$p/udp" >/dev/null; done
  grn "ufw 已放行"
elif command -v firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
  for p in $TCP_PORTS; do firewall-cmd -q --permanent --add-port="$p/tcp"; done
  for p in $UDP_PORTS; do firewall-cmd -q --permanent --add-port="$p/udp"; done
  firewall-cmd -q --reload; grn "firewalld 已放行"
else
  ylw "未检测到启用的防火墙（ufw/firewalld），跳过。若云厂商有安全组，请放行：TCP $TCP_PORTS / UDP $UDP_PORTS"
fi

# ---------------------------------------------------------------- 验证
step "验证"
FAIL=0
for p in $PANEL_PORT $SUB_PORT $P_TROJAN $P_VMESS; do
  # 注意：握手失败时 openssl 也会打印 "Verify return code: 0"，所以必须同时确认拿到了证书
  if echo | timeout 6 openssl s_client -connect "127.0.0.1:$p" -servername "$DOMAIN" \
       -verify_hostname "$DOMAIN" -verify_return_error 2>/dev/null | openssl x509 -noout -checkhost "$DOMAIN" 2>/dev/null | grep -q 'does match'; then
    grn "  TCP $p 证书 OK"
  else
    red "  TCP $p 证书校验失败"; FAIL=1
  fi
done
r=$(echo | timeout 6 openssl s_client -connect "127.0.0.1:$P_VLESS" -servername "$REALITY_TARGET" 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null || true)
[ -n "$r" ] && grn "  Reality $P_VLESS 握手 OK（${r#subject=}）" || { red "  Reality $P_VLESS 握手失败"; FAIL=1; }
for p in $UDP_PORTS; do
  ss -ulnH "sport = :$p" | grep -q . && grn "  UDP $p 监听 OK" || { red "  UDP $p 未监听"; FAIL=1; }
done

SUB_URL="https://${DOMAIN}:${SUB_PORT}${SUB_PATH}${CLIENT_NAME}"
LINKS="$(curl -fsS --max-time 10 --resolve "${DOMAIN}:${SUB_PORT}:127.0.0.1" "$SUB_URL" | base64 -d 2>/dev/null || true)"
[ "$(echo "$LINKS" | grep -c '://')" -ge 5 ] && grn "  订阅 OK（$(echo "$LINKS" | grep -c '://') 个节点）" || { red "  订阅获取异常"; FAIL=1; }

# ---------------------------------------------------------------- 输出
INFO=/root/sui-info.txt
umask 077
cat > "$INFO" <<EOF
================= s-ui 部署信息 ($(date '+%F %T')) =================
s-ui 版本 : $(/usr/local/s-ui/sui -v | tr '\n' ' ')
面板地址  : https://${DOMAIN}:${PANEL_PORT}${PANEL_PATH}
面板账号  : ${ADMIN_USER}
面板密码  : ${ADMIN_PASS}
订阅地址  : ${SUB_URL}

节点（端口）:
  VLESS Reality Vision : ${P_VLESS}/tcp   伪装 ${REALITY_TARGET}
  Hysteria2            : ${P_HY2}/udp   伪装 ${MASQUERADE_URL}
  TUIC v5              : ${P_TUIC}/udp
  Trojan TLS           : ${P_TROJAN}/tcp
  VMess TLS            : ${P_VMESS}/tcp

证书      : ${CERT}（acme.sh 自动续期，续期后自动重启 s-ui）
单节点链接:
${LINKS}
====================================================================
EOF
echo; cat "$INFO"; echo
grn "以上信息已保存到 $INFO（仅 root 可读）"
grn "把「订阅地址」添加到 v2rayN → 订阅分组 → 更新订阅 即可使用。"
[ $FAIL = 0 ] || ylw "有验证项失败，见上方红字。日志：journalctl -u s-ui -n 100"
