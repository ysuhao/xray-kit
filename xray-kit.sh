#!/usr/bin/env bash
# xray-kit.sh  -  Xray 一键部署：VLESS-Reality (TCP) + Hysteria2 (UDP, Salamander 混淆, 端口跳跃)，并生成 Clash Mi 配置。
#                 可选第二步：再接一台出口机（比如住宅 IP）做链式代理：普通流量从出口机出去，
#                 视频、下载这类大流量仍从第一台直出。
# 系统：Debian 11+ / Ubuntu 20.04+（RHEL 系大概率可用），root 运行。配套说明：1-部署节点.md、2-链式出口.md
#
#   bash xray-kit.sh install [--name 名字] [--sni 伪装站] [--port Reality端口]   第一台：部署节点，生成 clash-mi.yaml
#   bash xray-kit.sh exit --relay-ip 第一台IP [--name 名字] [--port 端口]        第二台：部署出口，输出 XKIT1: 开头的口令
#                    [--no-lockdown]   默认关闭出口机公网上的所有入站端口，只放行 SSH 和第一台；加这个参数则只管出口端口
#   bash xray-kit.sh chain <口令 | 口令文件 | ->                                回到第一台：接上出口，重新生成 clash-mi.yaml
#   bash xray-kit.sh unchain                                                    第一台：拆掉链式，全部流量恢复本机直出
#   bash xray-kit.sh test                                                       自检
#   bash xray-kit.sh show                                                       再看一次结果和文件位置
#
# 只动 Xray 自己的东西：/usr/local/etc/xray、/root/xray-kit、xray-kit-*.service、nft 表 xray_kit_*。
# 不改 SSH，不碰其他服务；发现 443 被别的程序占用或已有别人的 Xray 配置就停下。
# 出口机例外：默认把公网入站收紧到只剩 SSH 和第一台（nft 表 xray_kit_exit），--no-lockdown 关掉这一项。
set -uo pipefail
trap '' HUP PIPE   # SSH 断了也继续跑完（日志在 /root/xray-kit/run.log）

KIT=${XKIT_DIR:-/usr/local/etc/xray/kit}
OUT=${XKIT_OUT:-/root/xray-kit}
CONF=${XKIT_CONF:-/usr/local/etc/xray/config.json}
SEC=$KIT/secrets.env
SEL='🚀 节点选择'
SNI_CANDIDATES="www.csulb.edu www.ucr.edu www.ucla.edu www.berkeley.edu www.openbsd.org addons.mozilla.org"

die(){ echo "❌ $*" >&2; exit 1; }
log(){ echo "==> $*"; }
ok(){ echo "✅ $*"; }
warn(){ echo "⚠️  $*"; }
get(){ [ -f "$SEC" ] && grep -m1 "^$1=" "$SEC" | cut -d= -f2- || true; }
put(){ mkdir -p "$KIT"; touch "$SEC"; chmod 600 "$SEC"
  if grep -q "^$1=" "$SEC"; then sed -i "s|^$1=.*|$1=$2|" "$SEC"; else printf '%s=%s\n' "$1" "$2" >> "$SEC"; fi; }
is_ip(){ [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
rnd(){ openssl rand -base64 24 | tr -d '/+=\n'; }
clean_name(){ printf '%s' "$1" | LC_ALL=C tr -cd 'A-Za-z0-9_.\200-\377-'; }

# ---------------------------------------------------------------- arguments
CMD=${1:-help}; [ $# -gt 0 ] && shift
ARG_NAME="" ARG_SNI="" ARG_PORT="" ARG_RELAY="" ARG_LOCK="" FORCE=0 POS=""
while [ $# -gt 0 ]; do
  case $1 in
    --name|--sni|--port|--relay-ip)
      [ $# -ge 2 ] || die "$1 后面要跟一个值"
      case $1 in --name) ARG_NAME=$(clean_name "$2");; --sni) ARG_SNI=$2;; --port) ARG_PORT=$2;; --relay-ip) ARG_RELAY=$2;; esac
      shift 2;;
    --force) FORCE=1; shift;;
    --no-lockdown) ARG_LOCK=0; shift;;
    --lockdown) ARG_LOCK=1; shift;;
    *) POS=$1; shift;;
  esac
done

# ---------------------------------------------------------------- system helpers
need_root(){ [ "$(id -u)" = 0 ] || die "请用 root 运行（先 sudo -i）"; command -v systemctl >/dev/null || die "系统没有 systemd，不支持"; }
start_log(){ mkdir -p "$OUT"; chmod 700 "$OUT"; exec > >(tee -a -p "$OUT/run.log") 2>&1; echo; echo "######## $(date '+%F %T') xray-kit $CMD"; }

pkgs(){
  local c miss=0
  for c in curl openssl nft shuf base64 ss; do command -v $c >/dev/null || miss=1; done
  [ $miss = 0 ] && return
  log "安装依赖（curl openssl nftables ...）"
  if command -v apt-get >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl openssl nftables coreutils iproute2 ca-certificates unzip >/dev/null
  elif command -v dnf >/dev/null; then dnf install -y -q curl openssl nftables coreutils iproute ca-certificates unzip
  elif command -v yum >/dev/null; then yum install -y -q curl openssl nftables coreutils iproute ca-certificates unzip
  else die "不认识的系统（需要 Debian/Ubuntu/RHEL 系）"; fi
  for c in curl openssl base64 ss; do command -v $c >/dev/null || die "依赖 $c 装不上"; done
}

install_xray(){
  local v=0
  command -v xray >/dev/null && v=$(xray version 2>/dev/null | awk 'NR==1{split($2,a,"."); print a[1]+0}')
  if [ "${v:-0}" -lt 26 ]; then
    log "安装 / 升级 Xray（官方脚本，需要能访问 github.com）"
    bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 \
      || die "Xray 安装失败：服务器访问 github.com 是否正常？"
  fi
  command -v xray >/dev/null || die "没找到 xray 命令"
  ok "Xray $(xray version | awk 'NR==1{print $2}')"
  # the group the service runs as: older installers used nobody:nogroup, since 26.11 it is xray:xray
  local u; XGRP=$(systemctl show -p Group --value xray 2>/dev/null)
  if [ -z "$XGRP" ]; then u=$(systemctl show -p User --value xray 2>/dev/null); [ -n "$u" ] && XGRP=$(id -gn "$u" 2>/dev/null); fi
  [ -n "$XGRP" ] || XGRP=$(id -gn nobody 2>/dev/null || echo nogroup)
}

myip(){ local u ip; for u in https://api.ipify.org https://ifconfig.me/ip https://ipinfo.io/ip; do
  ip=$(curl -4 -fsS -m 8 "$u" 2>/dev/null | tr -d ' \n'); is_ip "$ip" && { echo "$ip"; return; }; done; }

pick_sni(){ local h
  for h in $SNI_CANDIDATES; do
    [ "$(curl -s -o /dev/null -m 6 --tlsv1.3 --http2 -w '%{http_version}' "https://$h/" 2>/dev/null)" = 2 ] && { echo "$h"; return; }
  done; }

port_owner(){ ss -Hlnp"$1" "sport = :$2" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2; }
check_port(){ local p; p=$(port_owner "$1" "$2")
  [ -z "$p" ] || [ "$p" = xray ] || die "$3 端口 $2 已被「$p」占用。本脚本不会动别的服务：请让用户决定是停掉它还是换端口（--port）"; }

guard_existing(){
  [ -f "$CONF" ] || return 0
  grep -q '"xkit-' "$CONF" && return 0
  [ "$(tr -d ' \t\r\n' < "$CONF")" = "{}" ] && return 0
  [ "$FORCE" = 1 ] && { warn "--force：原有 $CONF 会备份后覆盖"; return 0; }
  die "$CONF 已经存在，而且不是本脚本生成的（可能有人在用）。请先问用户；确认可以覆盖再加 --force（会自动备份）"
}

enable_bbr(){
  modprobe tcp_bbr 2>/dev/null
  cat > /etc/sysctl.d/99-xray-kit.conf <<'EOF'
# xray-kit: bigger UDP buffers for Hysteria2 (QUIC)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
  if sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' >> /etc/sysctl.d/99-xray-kit.conf
  fi
  sysctl -q -p /etc/sysctl.d/99-xray-kit.conf >/dev/null 2>&1
  [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = bbr ] && ok "BBR 已开启" || warn "这台机器开不了 BBR（容器类 VPS 常见），不影响使用"
}

# open_ports 443/tcp 443/udp 30000:39999/udp  (only touches a firewall that is actually on)
open_ports(){
  local p proto port
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    for p in "$@"; do ufw allow "$p" >/dev/null; done; ok "ufw 已放行：$*"; return
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    for p in "$@"; do firewall-cmd -q --permanent --add-port="${p/:/-}"; done; firewall-cmd -q --reload; ok "firewalld 已放行：$*"; return
  fi
  if command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT DROP|-j (REJECT|DROP)'; then
    for p in "$@"; do proto=${p#*/}; port=${p%/*}
      iptables -C INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || iptables -I INPUT -p "$proto" --dport "$port" -j ACCEPT; done
    command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1
    ok "iptables 已放行：$*"
  fi
}

LAST_BAK=""
apply_config(){
  xray run -test -c "$KIT/config.new.json" > "$KIT/test.log" 2>&1 || { cat "$KIT/test.log"; die "生成的 Xray 配置没通过校验（原因见上）"; }
  mkdir -p "$OUT/backup"
  if [ -f "$CONF" ]; then LAST_BAK="$OUT/backup/config.json.$(date +%Y%m%d-%H%M%S)"; cp -a "$CONF" "$LAST_BAK"; fi
  cp -a "$SEC" "$OUT/backup/secrets.env.$(date +%Y%m%d-%H%M%S)"
  install -o root -g "$XGRP" -m 640 "$KIT/config.new.json" "$CONF"
  systemctl enable xray >/dev/null 2>&1; systemctl restart xray; sleep 2
  if ! systemctl is-active --quiet xray; then
    journalctl -u xray -n 20 --no-pager -o cat
    if [ -n "$LAST_BAK" ]; then cp -a "$LAST_BAK" "$CONF"; systemctl restart xray; warn "已恢复上一份配置"; fi
    die "Xray 启动失败（日志见上）"
  fi
  ok "Xray 已用新配置运行"
}

# ---------------------------------------------------------------- outbound builders (also used by the self tests)
ob_reality(){ # addr port uuid sni pub sid [tag]
  printf '{"tag": "%s", "protocol": "vless", "settings": {"vnext": [{"address": "%s", "port": %s, "users": [{"id": "%s", "flow": "xtls-rprx-vision", "encryption": "none"}]}]}, "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"serverName": "%s", "fingerprint": "chrome", "password": "%s", "shortId": "%s"}, "sockopt": {"tcpFastOpen": true, "tcpKeepAliveIdle": 45, "tcpKeepAliveInterval": 15}}}' \
    "${7:-out}" "$1" "$2" "$3" "$4" "$5" "$6"; }
ob_hy2(){ # addr port auth sni fingerprint obfs
  printf '{"tag": "out", "protocol": "hysteria", "settings": {"version": 2, "address": "%s", "port": %s}, "streamSettings": {"network": "hysteria", "hysteriaSettings": {"version": 2, "auth": "%s"}, "security": "tls", "tlsSettings": {"serverName": "%s", "alpn": ["h3"], "pinnedPeerCertSha256": "%s"}, "finalmask": {"udp": [{"type": "salamander", "settings": {"password": "%s"}}]}}}' "$@"; }

# probe '<outbound json>' url1 [url2]  ->  "body1|body2"
probe(){
  local ob=$1 tmp pid u r="" port="" i; shift
  # a fresh free port each time: xray listens with SO_REUSEPORT, so a leftover listener would silently share the port
  for i in $(shuf -i 20000-29999 -n 30); do [ -z "$(ss -Hltn "sport = :$i")" ] && { port=$i; break; }; done
  [ -n "$port" ] || { printf ''; return; }
  tmp=$(mktemp -d /tmp/xkit-probe.XXXXXX)
  printf '{"log": {"loglevel": "none"}, "inbounds": [{"listen": "127.0.0.1", "port": %s, "protocol": "socks", "settings": {"udp": false}}], "outbounds": [%s]}' "$port" "$ob" > "$tmp/c.json"
  command xray run -c "$tmp/c.json" > "$tmp/log" 2>&1 & pid=$!
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(ss -Hltn "sport = :$port")" ] && break; sleep 0.5; done
  for u in "$@"; do r+="$(curl -s -m 15 --socks5-hostname 127.0.0.1:$port "$u" 2>/dev/null | tr -d '\r\n')|"; done
  kill $pid 2>/dev/null; pkill -f "$tmp/c.json" 2>/dev/null; wait $pid 2>/dev/null; rm -rf "$tmp"
  printf '%s' "${r%|}"
}
trace_ip(){ printf '%s' "$1" | grep -o 'ip=[0-9.]*' | head -1 | cut -d= -f2; }
FAILS=0
check(){ if [ -n "$2" ] && [ "$2" = "$3" ]; then ok "$1：$2"; else echo "❌ $1：得到「${2:-无响应}」，应该是 $3"; FAILS=$((FAILS+1)); fi; }

# ---------------------------------------------------------------- relay node (first server)
BULK_GEOSITE="youtube twitch vimeo dailymotion spotify soundcloud steam epicgames blizzard ea xbox playstation nintendo ubisoft apple-update docker github huggingface npmjs mega dropbox onedrive speedtest category-porn"
BULK_DOMAIN="googlevideo.com ytimg.com ggpht.com video.twimg.com v.redd.it cdn.discordapp.com media.discordapp.net windowsupdate.com update.microsoft.com delivery.mp.microsoft.com download.microsoft.com dl.google.com files.pythonhosted.org pypi.org download.nvidia.com download.jetbrains.com speed.cloudflare.com deb.debian.org archive.ubuntu.com releases.ubuntu.com drive.google.com drive.usercontent.google.com docs.googleusercontent.com googledrive.com colab.research.google.com colab.googleusercontent.com"
bulk_json(){ local s="" x
  for x in $BULK_GEOSITE; do s+="${s:+, }\"geosite:$x\""; done
  for x in $BULK_DOMAIN; do s+="${s:+, }\"domain:$x\""; done
  printf '%s' "$s"; }

render_node(){
  local sniff='{"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}'
  local exit_ob="" mid="" final=direct
  if [ -n "$(get EXIT_IP)" ]; then
    exit_ob=", $(ob_reality "$(get EXIT_IP)" "$(get EXIT_PORT)" "$(get EXIT_UUID)" "$(get EXIT_SNI)" "$(get EXIT_PUB)" "$(get EXIT_SID)" exit)"
    final=exit
    # solo = the "直出" line, always leaves here; bulk = heavy traffic, leaves here; everything else goes to the exit
    mid='
    {"type": "field", "user": ["solo@xkit", "solo-hy2@xkit"], "outboundTag": "direct"},
    {"type": "field", "domain": ['"$(bulk_json)"'], "outboundTag": "direct"},'
  fi
  mkdir -p "$KIT"
  cat > "$KIT/config.new.json" <<EOF
{
  "log": {"loglevel": "warning", "access": "none", "dnsLog": false},
  "dns": {"servers": ["https+local://1.1.1.1/dns-query", "https+local://8.8.8.8/dns-query"], "queryStrategy": "UseIPv4"},
  "inbounds": [
    {"tag": "xkit-reality", "listen": "0.0.0.0", "port": $(get REALITY_PORT), "protocol": "vless",
     "settings": {"clients": [
        {"id": "$(get UUID_MAIN)", "flow": "xtls-rprx-vision", "email": "main@xkit"},
        {"id": "$(get UUID_SOLO)", "flow": "xtls-rprx-vision", "email": "solo@xkit"}], "decryption": "none"},
     "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"show": false, "target": "$(get SNI):443", "xver": 0, "serverNames": ["$(get SNI)"],
                            "privateKey": "$(get REALITY_PRIV)", "shortIds": ["$(get SID_MAIN)", "$(get SID_SOLO)"]},
        "sockopt": {"tcpFastOpen": true, "tcpKeepAliveIdle": 45, "tcpKeepAliveInterval": 15}},
     "sniffing": $sniff},
    {"tag": "xkit-hy2", "listen": "0.0.0.0", "port": 443, "protocol": "hysteria",
     "settings": {"version": 2, "users": [
        {"auth": "$(get HY2_MAIN)", "email": "main-hy2@xkit"},
        {"auth": "$(get HY2_SOLO)", "email": "solo-hy2@xkit"}]},
     "streamSettings": {"network": "hysteria", "hysteriaSettings": {"version": 2, "udpIdleTimeout": 60},
        "security": "tls", "tlsSettings": {"alpn": ["h3"], "certificates": [
            {"certificateFile": "$KIT/hy2.crt", "keyFile": "$KIT/hy2.key"}]},
        "finalmask": {"udp": [{"type": "salamander", "settings": {"password": "$(get OBFS)"}}]}},
     "sniffing": $sniff}],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "streamSettings": {"sockopt": {"tcpFastOpen": true, "domainStrategy": "ForceIPv4"}}},
    {"tag": "block", "protocol": "blackhole"}$exit_ob],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
    {"type": "field", "ip": ["::/0"], "outboundTag": "block"},
    {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
    {"type": "field", "domain": ["geosite:cn"], "outboundTag": "block"},
    {"type": "field", "ip": ["geoip:cn"], "outboundTag": "block"},$mid
    {"type": "field", "network": "tcp,udp", "outboundTag": "$final"}]},
  "policy": {"levels": {"0": {"handshake": 4, "connIdle": 300}}}
}
EOF
}

setup_hop(){
  local NFT; NFT=$(command -v nft)
  if [ -z "$NFT" ] || ! nft list tables >/dev/null 2>&1; then put HOP 0; warn "这台机器用不了 nftables，跳过 UDP 端口跳跃（HY2 仍可用）"; return; fi
  cat > /etc/xray-kit-hop.nft <<'EOF'
table ip xray_kit_hop
delete table ip xray_kit_hop
table ip xray_kit_hop {
	chain prerouting {
		type nat hook prerouting priority dstnat; policy accept;
		udp dport 30000-39999 redirect to :443
	}
}
EOF
  cat > /etc/systemd/system/xray-kit-hop.service <<EOF
[Unit]
Description=xray-kit: Hysteria2 UDP port hopping (30000-39999 -> 443)
After=network-pre.target nftables.service
Before=xray.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT -f /etc/xray-kit-hop.nft
ExecStop=$NFT delete table ip xray_kit_hop
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable xray-kit-hop.service >/dev/null 2>&1; systemctl restart xray-kit-hop.service
  if nft list table ip xray_kit_hop >/dev/null 2>&1; then put HOP 1; ok "UDP 端口跳跃 30000-39999 → 443"; else put HOP 0; warn "端口跳跃没生效，跳过"; fi
}

init_node(){
  local r; r=$(get ROLE)
  [ -n "$r" ] && [ "$r" != node ] && die "这台机器之前被部署成了出口机（exit）。一台机器只能当一种角色"
  mkdir -p "$KIT"; chown root:"$XGRP" "$KIT"; chmod 750 "$KIT"
  put ROLE node
  [ -n "$ARG_NAME" ] && put NAME "$ARG_NAME"; [ -n "$(get NAME)" ] || put NAME VPS
  local ip; ip=$(myip); is_ip "$ip" || die "查不到这台服务器的公网 IPv4（服务器能上网吗？是不是纯 IPv6 机器？）"; put SERVER_IP "$ip"
  [ -n "$ARG_PORT" ] && put REALITY_PORT "$ARG_PORT"; [ -n "$(get REALITY_PORT)" ] || put REALITY_PORT 443
  if [ -n "$ARG_SNI" ]; then put SNI "$ARG_SNI"; elif [ -z "$(get SNI)" ]; then
    log "挑选 Reality 伪装站点"; local s; s=$(pick_sni); [ -n "$s" ] || die "候选伪装站都连不上，请用 --sni 指定一个支持 TLS1.3+H2 的国外网站"; put SNI "$s"; fi
  if [ -z "$(get REALITY_PRIV)" ]; then
    local kp; kp=$(xray x25519)
    put REALITY_PRIV "$(printf '%s\n' "$kp" | awk -F': *' 'tolower($1)~/^private/{print $2; exit}')"
    put REALITY_PUB "$(printf '%s\n' "$kp" | awk -F': *' 'tolower($1)~/^(password|public)/{print $2; exit}')"
    [ -n "$(get REALITY_PUB)" ] || die "Reality 密钥生成失败"
  fi
  local U; for U in MAIN SOLO; do
    [ -n "$(get UUID_$U)" ] || put UUID_$U "$(xray uuid)"
    [ -n "$(get SID_$U)" ] || put SID_$U "$(openssl rand -hex 8)"
    [ -n "$(get HY2_$U)" ] || put HY2_$U "$(rnd)"
  done
  [ -n "$(get OBFS)" ] || put OBFS "$(rnd)"
  if [ ! -f "$KIT/hy2.crt" ] || [ "$(get CERT_SNI)" != "$(get SNI)" ]; then
    openssl ecparam -genkey -name prime256v1 -out "$KIT/hy2.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "$KIT/hy2.key" -out "$KIT/hy2.crt" -subj "/CN=$(get SNI)" -addext "subjectAltName=DNS:$(get SNI)" 2>/dev/null \
      || die "HY2 证书生成失败"
    put CERT_SNI "$(get SNI)"
  fi
  put HY2_FP "$(openssl x509 -in "$KIT/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr A-F a-f)"
  chown root:"$XGRP" "$KIT/hy2.key" "$KIT/hy2.crt"; chmod 640 "$KIT/hy2.key"; chmod 644 "$KIT/hy2.crt"
}

test_node(){
  FAILS=0
  local me ex chained=0 proto U ob r label want
  me=$(get SERVER_IP); [ -n "$(get EXIT_IP)" ] && chained=1; ex=$(get EXIT_EGRESS); [ -n "$ex" ] || ex=$(get EXIT_IP)
  log "自检（在服务器本机模拟客户端连自己）"
  for proto in Reality HY2; do for U in MAIN SOLO; do
    [ $U = SOLO ] && [ $chained = 0 ] && continue
    if [ $proto = Reality ]; then ob=$(ob_reality 127.0.0.1 "$(get REALITY_PORT)" "$(get UUID_$U)" "$(get SNI)" "$(get REALITY_PUB)" "$(get SID_$U)")
    else ob=$(ob_hy2 127.0.0.1 443 "$(get HY2_$U)" "$(get SNI)" "$(get HY2_FP)" "$(get OBFS)"); fi
    r=$(probe "$ob" https://api.ipify.org https://speed.cloudflare.com/cdn-cgi/trace)
    label="$proto"; [ $chained = 1 ] && { [ $U = MAIN ] && label="$proto 链式线路" || label="$proto 直出线路"; }
    want=$me; [ $U = MAIN ] && [ $chained = 1 ] && want=$ex
    check "$label 普通流量出口" "${r%%|*}" "$want"
    [ $chained = 1 ] && check "$label 大流量(视频/下载)出口" "$(trace_ip "${r#*|}")" "$me"
  done; done
  [ $FAILS = 0 ] && ok "自检全部通过" || echo "❌ 自检有 $FAILS 项没过"
  return $FAILS
}

# ---------------------------------------------------------------- Clash Mi profile
BROWSERS="chrome.exe msedge.exe msedgewebview2.exe firefox.exe brave.exe opera.exe vivaldi.exe 360se.exe 360chrome.exe QQBrowser.exe SogouExplorer.exe com.android.chrome org.mozilla.firefox com.microsoft.emmx"
CN_APPS="WeChat.exe Weixin.exe WeChatAppEx.exe WeChatApp.exe WeChatBrowser.exe WeChatPlayer.exe WXWork.exe WXWorkWeb.exe QQ.exe TIM.exe QQMusic.exe QQLive.exe wemeetapp.exe DingTalk.exe Feishu.exe AlibabaProtect.exe AliWorkbench.exe BaiduNetdisk.exe BaiduNetdiskHost.exe cloudmusic.exe wps.exe Thunder.exe iQIYI.exe douyin.exe com.tencent.mm com.tencent.mobileqq com.tencent.wework com.eg.android.AlipayGphone com.unionpay"
CN_DOMAINS="qq.com weixin.com wechat.com wechatpay.com tenpay.com servicewechat.com gtimg.com idqqimg.com tencent.com tencentcs.com myqcloud.com qcloud.com myapp.com weiyun.com alipay.com alipayobjects.com alipaydns.com alipay-eco.com alibaba.com alibabausercontent.com aliyun.com alicdn.com aliyuncs.com alikunlun.com taobao.com tmall.com tmall.hk 1688.com dingtalk.com amap.com autonavi.com youku.com ele.me fliggy.com unionpay.com 95516.com unionpaysecure.com chinaums.com icbc.com.cn ccb.com abchina.com boc.cn bankofchina.com bankcomm.com cmbchina.com cmbimg.com cmbc.com.cn cib.com.cn spdb.com.cn cebbank.com hxb.com.cn psbc.com citicbank.com cgbchina.com.cn pingan.com pingan.com.cn pab.com.cn bankofbeijing.com.cn bosc.cn njcb.com.cn hzbank.com.cn webank.com baidu.com bdstatic.com bdimg.com bcebos.com bilibili.com bilivideo.com bilicdn.com biliapi.net biliapi.com hdslb.com douyin.com douyincdn.com douyinpic.com douyinstatic.com douyinvod.com amemv.com snssdk.com toutiao.com toutiaoimg.com pstatp.com byteimg.com ixigua.com zijieapi.com feishucdn.com volces.com volccdn.com xiaohongshu.com xhscdn.com xhslink.com kuaishou.com kuaishouzt.com ksapisrv.com gifshow.com yximgs.com kwaicdn.com weibo.com weibocdn.com sina.com jd.com 360buyimg.com jdcloud.com jingdong.com pinduoduo.com yangkeduo.com pddpic.com meituan.com meituan.net dianping.com didiglobal.com xiaojukeji.com didichuxing.com 163.com 126.com 126.net 127.net netease.com yeah.net zhihu.com zhimg.com iqiyi.com qiyi.com iqiyipic.com mgtv.com ctrip.com qunar.com csdn.net cnblogs.com mi.com xiaomi.com miui.com huawei.com hicloud.com vmall.com oppo.com vivo.com 10010.com sf-express.com cainiao.com kuaidi100.com"
or_of(){ local k=$1 s="" x; shift; for x in "$@"; do s+="${s:+,}($k,$x)"; done; printf '(OR,(%s))' "$s"; }

yaml_hy2(){ # proxy-name user
  printf '  - name: %s\n    type: hysteria2\n    server: %s\n    port: 443\n' "$1" "$(get SERVER_IP)"
  [ "$(get HOP)" = 1 ] && printf '    ports: 30000-39999\n    hop-interval: 30\n'
  printf '    password: "%s"\n    obfs: salamander\n    obfs-password: "%s"\n    sni: %s\n    fingerprint: %s\n    alpn: [h3]\n    skip-cert-verify: false\n    udp: true\n' \
    "$(get HY2_$2)" "$(get OBFS)" "$(get SNI)" "$(get HY2_FP)"; }
yaml_reality(){ # proxy-name user
  printf '  - name: %s\n    type: vless\n    server: %s\n    port: %s\n    uuid: %s\n    network: tcp\n    tls: true\n    udp: true\n    flow: xtls-rprx-vision\n    servername: %s\n    client-fingerprint: chrome\n    reality-opts:\n      public-key: %s\n      short-id: %s\n      # Xray 26.7+ 的 Reality 服务端要求客户端带这个，否则握手失败\n      support-x25519mlkem768: true\n' \
    "$1" "$(get SERVER_IP)" "$(get REALITY_PORT)" "$(get UUID_$2)" "$(get SNI)" "$(get REALITY_PUB)" "$(get SID_$2)"; }
yaml_group(){ # group-name
  printf '  - name: %s\n    type: fallback\n    proxies: [%s-HY2, %s-Reality]\n    url: https://cp.cloudflare.com/generate_204\n    interval: 120\n    lazy: false\n    hidden: true\n' "$1" "$1" "$1"; }

render_clash(){
  local N lines=() users=() i proxies="" groups="" sel_list="" title
  N=$(get NAME)
  if [ -n "$(get EXIT_IP)" ]; then
    lines=("$N→$(get EXIT_NAME)" "$N直出"); users=(MAIN SOLO)
    title="$N（链式：普通流量从 $(get EXIT_NAME) 出，视频/下载从 $N 出；「$N直出」全部从 $N 出）"
  else
    lines=("$N"); users=(MAIN); title="$N（Reality + Hysteria2）"
  fi
  for i in "${!lines[@]}"; do
    proxies+="$(yaml_hy2 "${lines[$i]}-HY2" "${users[$i]}")"$'\n'"$(yaml_reality "${lines[$i]}-Reality" "${users[$i]}")"$'\n'
    groups+="$(yaml_group "${lines[$i]}")"$'\n'
    sel_list+="${sel_list:+, }${lines[$i]}"
  done
  local browser stun ai d rules_cn="" a rules_apps=""
  browser=$(or_of PROCESS-NAME $BROWSERS)
  stun=$(or_of DST-PORT 3478 3479 5349 19302-19309)
  ai=$(or_of GEOSITE openai anthropic google-gemini perplexity xai)
  for a in $CN_APPS; do rules_apps+="  - PROCESS-NAME,$a,DIRECT"$'\n'; done
  for d in $CN_DOMAINS; do rules_cn+="  - DOMAIN-SUFFIX,$d,DIRECT"$'\n'; done
  local CN_DNS="['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query']"
  mkdir -p "$OUT"
  cat > "$OUT/clash-mi.yaml" <<EOF
# $title - xray-kit $(date +%F)
# Clash Mi 导入后：覆写选「内置-不覆写」，并关掉 TUN 覆写；否则它会换成自己的 DNS/TUN 设置，造成 DNS 泄露。
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: false
unified-delay: true
tcp-concurrent: true
find-process-mode: strict
geodata-mode: true
geo-auto-update: true
geo-update-interval: 72
profile:
  store-selected: true

sniffer:
  enable: true
  force-dns-mapping: true
  parse-pure-ip: true
  sniff:
    HTTP: {ports: [80, 8080-8880], override-destination: true}
    TLS: {ports: [443, 8443]}
    QUIC: {ports: [443, 8443]}

tun:
  enable: true
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  # 防止 Windows 同时向物理网卡的 DNS 发请求（DNS 泄露）
  strict-route: true
  dns-hijack: [any:53, tcp://any:53]
  # 只为把 IPv6 收进隧道再由第一条规则丢掉；IPv6 不走代理
  inet6-address: [fdfe:dcba:9876::1/126]

dns:
  enable: true
  ipv6: false
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  fake-ip-filter: ['*.lan', '+.local', '+.msftconnecttest.com', '+.msftncsi.com', 'time.*.com', '+.ntp.org', '+.pool.ntp.org']
  # 全部加密 DNS，没有明文 UDP DNS，也不用系统 DNS
  default-nameserver: $CN_DNS
  # 不确定是国内的域名一律经代理远程解析（本地运营商看不到）
  nameserver: ['https://1.1.1.1/dns-query#$SEL', 'https://8.8.8.8/dns-query#$SEL']
  proxy-server-nameserver: $CN_DNS
  direct-nameserver: $CN_DNS
  nameserver-policy:
    'geosite:cn,private': $CN_DNS

proxies:
${proxies%$'\n'}

proxy-groups:
  - name: $SEL
    type: select
    proxies: [$sel_list]
${groups%$'\n'}

rules:
  # IPv6 一律不走：任何 IPv6 目标在这里被丢掉，不会绕过隧道
  - IP-CIDR6,::/0,REJECT,no-resolve
  - GEOSITE,private,DIRECT
  - GEOIP,private,DIRECT,no-resolve
  # AI 网站禁用 QUIC，强制 TCP
  - AND,((NETWORK,UDP),(DST-PORT,443),$ai),REJECT
  # 国内 App 直连（含语音视频通话）
${rules_apps%$'\n'}
  # WebRTC：浏览器的 UDP 不许直连，否则对国内 STUN 服务器会暴露真实 IP
  - AND,((NETWORK,UDP),(DST-PORT,443),(OR,((GEOSITE,cn),(GEOIP,CN))),$browser),REJECT
  - AND,((NETWORK,UDP),$browser),$SEL
  - AND,((NETWORK,UDP),$stun),$SEL
  # 国内服务直连：微信、支付宝、银联、银行和常用 App
  - GEOSITE,tencent,DIRECT
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOSITE,category-bank-cn,DIRECT
${rules_cn%$'\n'}
  - GEOSITE,cn,DIRECT
  - GEOIP,CN,DIRECT
  - MATCH,$SEL
EOF
  chmod 600 "$OUT/clash-mi.yaml"
}

summary_node(){
  echo
  echo "================================================================"
  echo " Clash Mi 配置文件：$OUT/clash-mi.yaml"
  echo " 服务器：$(get NAME)  $(get SERVER_IP)"
  echo "   Reality  TCP $(get REALITY_PORT)（伪装站 $(get SNI)）"
  printf '   HY2      UDP 443'; [ "$(get HOP)" = 1 ] && printf '（端口跳跃 UDP 30000-39999）'; echo
  if [ -n "$(get EXIT_IP)" ]; then
    echo " 链式出口：$(get EXIT_NAME)  $(get EXIT_IP):$(get EXIT_PORT)（实际出口 IP $(get EXIT_EGRESS)）"
    echo "   「$(get NAME)→$(get EXIT_NAME)」：普通流量从出口机出，视频/下载/网盘从本机出；出口机挂了这条线不通（不会偷偷换 IP）"
    echo "   「$(get NAME)直出」：全部从本机出，出口机坏了用它"
  fi
  echo " 云服务商控制台的安全组/防火墙要放行：TCP $(get REALITY_PORT)、UDP 443、UDP 30000-39999"
  echo "================================================================"
}

# ---------------------------------------------------------------- exit node (second server)
render_exit(){
  local relays="" r
  for r in ${RELAYS//,/ } 127.0.0.1; do relays+="${relays:+, }\"$r\""; done
  mkdir -p "$KIT"
  cat > "$KIT/config.new.json" <<EOF
{
  "log": {"loglevel": "warning", "access": "none", "dnsLog": false},
  "dns": {"servers": ["https+local://1.1.1.1/dns-query", "https+local://8.8.8.8/dns-query"], "queryStrategy": "UseIPv4"},
  "inbounds": [
    {"tag": "xkit-exit", "listen": "0.0.0.0", "port": $(get PORT), "protocol": "vless",
     "settings": {"clients": [{"id": "$(get UUID_RELAY)", "flow": "xtls-rprx-vision", "email": "relay@xkit"}], "decryption": "none"},
     "streamSettings": {"network": "tcp", "security": "reality",
        "realitySettings": {"show": false, "target": "$(get SNI):443", "xver": 0, "serverNames": ["$(get SNI)"],
                            "privateKey": "$(get REALITY_PRIV)", "shortIds": ["$(get SID_RELAY)"]},
        "sockopt": {"tcpFastOpen": true, "tcpKeepAliveIdle": 45, "tcpKeepAliveInterval": 15}},
     "sniffing": {"enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true}}],
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "streamSettings": {"sockopt": {"tcpFastOpen": true, "domainStrategy": "ForceIPv4"}}},
    {"tag": "block", "protocol": "blackhole"}],
  "routing": {"domainStrategy": "IPIfNonMatch", "rules": [
    {"type": "field", "ip": ["::/0"], "outboundTag": "block"},
    {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"},
    {"type": "field", "protocol": ["bittorrent"], "outboundTag": "block"},
    {"type": "field", "domain": ["geosite:cn"], "outboundTag": "block"},
    {"type": "field", "ip": ["geoip:cn"], "outboundTag": "block"},
    {"type": "field", "source": [$relays], "network": "tcp,udp", "outboundTag": "direct"},
    {"type": "field", "network": "tcp,udp", "outboundTag": "block"}]},
  "policy": {"levels": {"0": {"handshake": 4, "connIdle": 300}}}
}
EOF
}

# ports sshd really listens on (also via ssh.socket), plus the port this session came in on
ssh_ports(){
  { ss -Hltnp 2>/dev/null | awk '/"(sshd|dropbear)"/{print $4}'
    ss -Htnp state established 2>/dev/null | awk '/"(sshd|dropbear)"/{print $3}'
    systemctl show -p Listen --value ssh.socket sshd.socket 2>/dev/null | tr ' ' '\n' | grep -E ':?[0-9]+$'
    command -v sshd >/dev/null && sshd -T 2>/dev/null | awk '$1=="port"{print $2}'
  } | sed -E 's/.*[]:]//; s/[^0-9].*//' | grep -E '^[0-9]+$' | awk '$1>0 && $1<65536' | sort -un | tr '\n' ' ' | sed 's/ $//'
}
# public listening ports that the lockdown will close (for the log only)
closed_ports(){ local keep=" $1 "
  ss -Hlntu 2>/dev/null | awk '{print $1, $5}' | grep -vE ' (127\.|\[::1\]|::1:|\[::ffff:127\.)' \
    | sed -E 's/^(tcp|udp) .*:([0-9]+)$/\2\/\1/' | grep -E '^[0-9]+/(tcp|udp)$' | sort -u -t/ -k1,1n -k2 \
    | while read -r x; do case $x in 68/udp|546/udp) continue;; esac; case "$keep" in *" ${x%/tcp} "*) [ "${x#*/}" = tcp ] && continue;; esac; printf '%s ' "$x"; done
}

exit_firewall(){ # lockdown (default): public NIC only lets in SSH, and the exit port from the relays. --no-lockdown: only guard the exit port
  local P r NFT set="" wan="" body sp; P=$(get PORT); NFT=$(command -v nft)
  for r in ${RELAYS//,/ }; do set+="${set:+, }$r"; done
  if [ -n "$NFT" ] && nft list tables >/dev/null 2>&1; then
    if [ "$(get LOCKDOWN)" = 1 ]; then
      sp=$SSHP
      wan=$({ ip -o route show default; ip -o -6 route show default; } 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev") print $(i+1)}' | sort -u | sed 's/.*/"&"/' | paste -sd, | sed 's/,/, /g')
      local cp; cp=$(closed_ports "$sp $P")
      body="	chain input {
		type filter hook input priority -5; policy accept;
		iif \"lo\" accept
		$([ -n "$wan" ] && echo "iifname { $wan } jump wan" || echo "jump wan")
	}
	chain wan {
		ct state established,related accept
		ct state invalid drop
		icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-advert, nd-router-solicit } accept
		udp sport 67 udp dport 68 accept
		udp sport 547 udp dport 546 accept
		tcp dport { ${sp// /, } } accept
		meta nfproto ipv4 ip saddr { $set } tcp dport $P accept
		drop
	}
	chain forward {
		type filter hook forward priority -5; policy accept;
		$([ -n "$wan" ] && echo "iifname { $wan } ")ct state new ct status dnat drop
	}"
    else
      body="	chain input {
		type filter hook input priority -5; policy accept;
		iif \"lo\" accept
		meta nfproto ipv4 tcp dport $P ip saddr != { $set } drop
		meta nfproto ipv6 tcp dport $P drop
	}"
    fi
    cat > /etc/xray-kit-exit.nft <<EOF
table inet xray_kit_exit
delete table inet xray_kit_exit
table inet xray_kit_exit {
$body
}
EOF
    cat > /etc/systemd/system/xray-kit-exit-fw.service <<EOF
[Unit]
Description=xray-kit: exit server firewall (SSH + relay servers only)
After=network-pre.target nftables.service
Before=xray.service
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$NFT -f /etc/xray-kit-exit.nft
ExecStop=$NFT delete table inet xray_kit_exit
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable xray-kit-exit-fw.service >/dev/null 2>&1; systemctl restart xray-kit-exit-fw.service
    if ! nft list table inet xray_kit_exit >/dev/null 2>&1; then warn "nft 防火墙没生效，仅靠 Xray 自身按来源拦截"
    elif [ "$(get LOCKDOWN)" = 1 ]; then
      ok "公网入站已关闭，只放行：SSH TCP ${sp// /、}；TCP $P 仅限 $set${wan:+（网卡 ${wan//\"/}）}"
      [ -n "$cp" ] && ok "这些端口还在监听，但外网已经连不进来：$cp"
    else ok "端口 $P 只对 $set 开放（其他来源静默丢弃）；其他端口未改动（--no-lockdown）"; fi
  else
    warn "用不了 nftables，仅靠 Xray 自身按来源拦截，其他端口未改动"
  fi
  # an active ufw/firewalld/iptables policy must let the relays in
  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    for r in ${RELAYS//,/ }; do ufw allow from "$r" to any port "$P" proto tcp >/dev/null; done; ok "ufw 已放行中转机"
  elif systemctl is-active --quiet firewalld 2>/dev/null; then
    for r in ${RELAYS//,/ }; do firewall-cmd -q --permanent --add-rich-rule="rule family=ipv4 source address=$r port port=$P protocol=tcp accept"; done
    firewall-cmd -q --reload; ok "firewalld 已放行中转机"
  elif command -v iptables >/dev/null && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT DROP|-j (REJECT|DROP)'; then
    for r in ${RELAYS//,/ }; do iptables -C INPUT -p tcp -s "$r" --dport "$P" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp -s "$r" --dport "$P" -j ACCEPT; done
    command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1; ok "iptables 已放行中转机"
  fi
}

# ---------------------------------------------------------------- commands
cmd_install(){
  need_root; start_log; pkgs; install_xray
  [ "$(get ROLE)" = node ] || guard_existing
  init_node
  check_port t "$(get REALITY_PORT)" "TCP"; check_port u 443 "UDP"
  enable_bbr; setup_hop
  open_ports "$(get REALITY_PORT)/tcp" 443/udp 30000:39999/udp
  render_node; apply_config
  test_node; local rc=$?
  render_clash; summary_node
  [ $rc = 0 ] || die "部署完成但自检没过，看上面的 ❌"
}

cmd_exit(){
  need_root; start_log; pkgs; install_xray
  local r; r=$(get ROLE); [ -n "$r" ] && [ "$r" != exit ] && die "这台机器之前被部署成了节点（install）。出口机要用另一台"
  [ "$r" = exit ] || guard_existing
  mkdir -p "$KIT"; chown root:"$XGRP" "$KIT"; chmod 750 "$KIT"
  put ROLE exit
  [ -n "$ARG_RELAY" ] && put RELAY_IPS "$ARG_RELAY"
  RELAYS=$(get RELAY_IPS); [ -n "$RELAYS" ] || die "缺少 --relay-ip 第一台服务器的IP"
  for r in ${RELAYS//,/ }; do is_ip "$r" || die "--relay-ip 里「$r」不是 IPv4 地址"; done
  [ -n "$ARG_LOCK" ] && put LOCKDOWN "$ARG_LOCK"; [ -n "$(get LOCKDOWN)" ] || put LOCKDOWN 1
  if [ "$(get LOCKDOWN)" = 1 ]; then
    SSHP=$(ssh_ports); [ -n "$SSHP" ] || die "找不到 sshd 监听的端口，不敢关闭其他端口（会把自己锁在外面）。确认 SSH 正常后重跑，或加 --no-lockdown"
  fi
  [ -n "$ARG_NAME" ] && put NAME "$ARG_NAME"; [ -n "$(get NAME)" ] || put NAME 出口
  local ip; ip=$(myip); is_ip "$ip" || die "查不到这台服务器的公网 IPv4"; put SERVER_IP "$ip"
  [ -n "$ARG_PORT" ] && put PORT "$ARG_PORT"; [ -n "$(get PORT)" ] || put PORT "$(shuf -i 40000-60000 -n1)"
  if [ -n "$ARG_SNI" ]; then put SNI "$ARG_SNI"; elif [ -z "$(get SNI)" ]; then
    log "挑选 Reality 伪装站点"; local s; s=$(pick_sni); [ -n "$s" ] || die "候选伪装站都连不上，请用 --sni 指定"; put SNI "$s"; fi
  if [ -z "$(get REALITY_PRIV)" ]; then
    local kp; kp=$(xray x25519)
    put REALITY_PRIV "$(printf '%s\n' "$kp" | awk -F': *' 'tolower($1)~/^private/{print $2; exit}')"
    put REALITY_PUB "$(printf '%s\n' "$kp" | awk -F': *' 'tolower($1)~/^(password|public)/{print $2; exit}')"
    [ -n "$(get REALITY_PUB)" ] || die "Reality 密钥生成失败"
  fi
  [ -n "$(get UUID_RELAY)" ] || put UUID_RELAY "$(xray uuid)"
  [ -n "$(get SID_RELAY)" ] || put SID_RELAY "$(openssl rand -hex 8)"
  check_port t "$(get PORT)" "TCP"
  enable_bbr; exit_firewall
  render_exit; apply_config
  log "自检"
  local eg; eg=$(probe "$(ob_reality 127.0.0.1 "$(get PORT)" "$(get UUID_RELAY)" "$(get SNI)" "$(get REALITY_PUB)" "$(get SID_RELAY)")" https://api.ipify.org)
  is_ip "$eg" || die "出口机本机自检失败：Xray 跑起来了但出不去网"
  put EGRESS "$eg"; ok "出口机上网正常，出口 IP $eg（$(curl -4 -s -m 8 https://ipinfo.io/org 2>/dev/null)）"
  local tok
  tok="XKIT1:$(printf 'EXIT_IP=%s\nEXIT_PORT=%s\nEXIT_UUID=%s\nEXIT_SID=%s\nEXIT_PUB=%s\nEXIT_SNI=%s\nEXIT_NAME=%s\nEXIT_EGRESS=%s\n' \
    "$(get SERVER_IP)" "$(get PORT)" "$(get UUID_RELAY)" "$(get SID_RELAY)" "$(get REALITY_PUB)" "$(get SNI)" "$(get NAME)" "$eg" | base64 -w0)"
  printf '%s\n' "$tok" > "$OUT/exit-token.txt"; chmod 600 "$OUT/exit-token.txt"
  echo
  echo "================================================================"
  echo " 出口机就绪：$(get NAME)  $(get SERVER_IP)  TCP $(get PORT)（只允许 $RELAYS 连接）"
  [ "$(get LOCKDOWN)" = 1 ] && echo " 公网入站只放行 SSH（TCP ${SSHP// /、}）和上面这个端口，其他端口全部关闭"
  echo " 云服务商控制台的安全组要放行 TCP $(get PORT)（来源可以只填 $RELAYS）"
  echo " 口令已存到 $OUT/exit-token.txt，下一步在第一台上运行："
  echo "   bash xray-kit.sh chain <口令>"
  echo "================================================================"
  echo "$tok"
}

cmd_chain(){
  need_root
  local src=$POS tok dec k v
  if [ -z "$src" ] || [ "$src" = - ]; then tok=$(cat); elif [ -f "$src" ]; then tok=$(cat "$src"); else tok=$src; fi
  start_log; install_xray
  [ "$(get ROLE)" = node ] || die "这台机器还没有用 install 部署过节点，先跑第一步"
  tok=$(printf '%s' "$tok" | tr -d ' \r\n'); tok=${tok##*XKIT1:}
  dec=$(printf '%s' "$tok" | base64 -d 2>/dev/null) || die "口令无效（应以 XKIT1: 开头，整段复制，不能改动）"
  declare -A T
  for k in EXIT_IP EXIT_PORT EXIT_UUID EXIT_SID EXIT_PUB EXIT_SNI EXIT_NAME EXIT_EGRESS; do
    v=$(printf '%s\n' "$dec" | grep -m1 "^$k=" | cut -d= -f2-); [ -n "$v" ] || die "口令不完整（缺 $k），请重新复制"; T[$k]=$v
  done
  [ "${T[EXIT_IP]}" = "$(get SERVER_IP)" ] && die "口令里的出口机就是本机，搞反了：exit 要在第二台上跑"
  log "先试连出口机 ${T[EXIT_IP]}:${T[EXIT_PORT]}（还没改任何配置）"
  local eg; eg=$(probe "$(ob_reality "${T[EXIT_IP]}" "${T[EXIT_PORT]}" "${T[EXIT_UUID]}" "${T[EXIT_SNI]}" "${T[EXIT_PUB]}" "${T[EXIT_SID]}")" https://api.ipify.org)
  if ! is_ip "$eg"; then
    echo "❌ 连不上出口机，本机配置没有改动。常见原因："
    echo "   1. 出口机云控制台的安全组没放行 TCP ${T[EXIT_PORT]}（来源 $(get SERVER_IP)）"
    echo "   2. 出口机上 --relay-ip 填的不是 $(get SERVER_IP)：回出口机重跑 exit --relay-ip $(get SERVER_IP)"
    echo "   3. 家宽/住宅线路封了这个入站端口：出口机上重跑 exit 并加 --port 换一个端口"
    exit 1
  fi
  ok "通过出口机上网正常，出口 IP $eg"
  for k in "${!T[@]}"; do put "$k" "${T[$k]}"; done
  put EXIT_EGRESS "$eg"
  render_node; apply_config
  test_node; local rc=$?
  render_clash; summary_node
  [ $rc = 0 ] || die "链式已配置但自检没过，看上面的 ❌（可以 bash xray-kit.sh unchain 撤回）"
}

cmd_unchain(){
  need_root; start_log; install_xray
  [ "$(get ROLE)" = node ] || die "这台机器不是用 install 部署的节点"
  [ -n "$(get EXIT_IP)" ] || { ok "本来就没有链式出口"; return; }
  sed -i '/^EXIT_/d' "$SEC"
  render_node; apply_config; test_node; render_clash; summary_node
  ok "已拆掉链式出口：全部流量从本机出。新的 clash-mi.yaml 需要重新导入"
}

cmd_test(){
  need_root; install_xray >/dev/null
  case $(get ROLE) in
    node) test_node;;
    exit) local eg; eg=$(probe "$(ob_reality 127.0.0.1 "$(get PORT)" "$(get UUID_RELAY)" "$(get SNI)" "$(get REALITY_PUB)" "$(get SID_RELAY)")" https://api.ipify.org)
          is_ip "$eg" && ok "出口机正常，出口 IP $eg" || die "出口机自检失败";;
    *) die "这台机器还没部署";;
  esac
}

cmd_show(){
  case $(get ROLE) in
    node) summary_node;;
    exit) echo "出口机 $(get NAME) $(get SERVER_IP) TCP $(get PORT)，允许 $(get RELAY_IPS)。口令：$OUT/exit-token.txt"
          if [ "$(get LOCKDOWN)" = 1 ]; then echo "公网入站只放行 SSH 和 $(get RELAY_IPS)；防火墙规则：nft list table inet xray_kit_exit"; fi;;
    *) die "这台机器还没部署";;
  esac
}

case $CMD in
  install) cmd_install;;
  exit) cmd_exit;;
  chain) cmd_chain;;
  unchain) cmd_unchain;;
  test) cmd_test;;
  show) cmd_show;;
  _render) RELAYS=$(get RELAY_IPS); [ "$(get ROLE)" = exit ] && render_exit || { render_node; render_clash; };;  # offline check, no root needed
  *) sed -n '2,20p' "$0"; exit 1;;
esac
