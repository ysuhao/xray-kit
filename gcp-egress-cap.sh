#!/usr/bin/env bash
# gcp-egress-cap.sh - install a monthly outbound-traffic cap on a GCP VM.
# GCP Standard network tier: the first 200 GiB of outbound traffic per month are free per billing account
# (billing month in US Pacific time). This counts what the VM sends and acts at the cap (default 195 GiB).
#
#   sudo bash gcp-egress-cap.sh                         install: 195 GiB, stop Xray at the cap
#   sudo bash gcp-egress-cap.sh --limit 150             another cap in GiB
#   sudo bash gcp-egress-cap.sh --action poweroff       power the VM off at the cap instead
#
# Afterwards:  egress-cap          this month's usage
#              egress-cap allow    stop enforcing for the rest of this month
#              egress-cap set 42   set this month's count (GiB), e.g. after checking the billing page
set -euo pipefail
LIMIT=195 ACTION=stop-xray
while [ $# -gt 0 ]; do
  case $1 in
    --limit) LIMIT=${2:?}; shift 2;;
    --action) ACTION=${2:?}; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done
[[ $LIMIT =~ ^[0-9]+$ ]] || { echo "--limit must be a whole number of GiB" >&2; exit 2; }
case $ACTION in stop-xray|poweroff) ;; *) echo "--action must be stop-xray or poweroff" >&2; exit 2;; esac
[ "$(id -u)" = 0 ] || { echo "run as root (sudo)" >&2; exit 1; }

cat > /usr/local/sbin/egress-cap <<'EGRESS_CAP'
#!/bin/bash
# egress-cap: count this VM's outbound bytes for the month and act at a cap.
# GCP Standard Tier: first 200 GiB/month free per billing account, billing
# month in US Pacific time. Default cap 195 GiB leaves a little margin.
#   egress-cap            show this month's usage (same as: egress-cap status)
#   egress-cap check      count and enforce; run every minute by egress-cap.timer
#   egress-cap allow      stop enforcing for the rest of this month (emergency)
#   egress-cap set GIB    overwrite this month's count, e.g. after checking billing
# Counts all bytes sent on the default-route NIC (includes Google-internal and
# header bytes), so it over-counts slightly, which errs on the safe side.
# Settings in /etc/egress-cap.conf (see egress-cap.conf).

set -u
CONF="${EGRESS_CAP_CONF:-/etc/egress-cap.conf}"
LIMIT_GIB=195
ACTION=poweroff          # poweroff | stop-xray
XRAY_UNIT=xray
IFACE=""                 # empty = NIC of the IPv4 default route
STATE=/var/lib/egress-cap
TX_FILE=""               # empty = /sys/class/net/$IFACE/statistics/tx_bytes
BOOT_FILE=/proc/sys/kernel/random/boot_id
DRY_RUN=0                # 1 = log the action instead of doing it
[ -r "$CONF" ] && . "$CONF"

GIB=$((1024 * 1024 * 1024))
limit=$((LIMIT_GIB * GIB))
month=$(TZ=America/Los_Angeles date +%Y-%m)

if [ -z "$TX_FILE" ]; then
  [ -n "$IFACE" ] || IFACE=$(ip -4 route show default | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  TX_FILE=/sys/class/net/$IFACE/statistics/tx_bytes
fi

log() { echo "$*"; logger -t egress-cap "$*" 2>/dev/null; }
gib() { awk -v b="$1" 'BEGIN{printf "%.2f GiB", b/1073741824}'; }

# state file: month used_bytes last_raw_tx boot_id flag
read_state() {
  s_month=""; s_used=0; s_raw=0; s_boot=""; s_flag=-
  [ -r "$STATE/state" ] && read -r s_month s_used s_raw s_boot s_flag < "$STATE/state"
}
save_state() {
  mkdir -p "$STATE"
  echo "$month $used $raw $boot $flag" > "$STATE/state.tmp" && mv "$STATE/state.tmp" "$STATE/state"
}

allowed() { [ "$(cat "$STATE/allow" 2>/dev/null)" = "$month" ]; }

act() {  # run a command, or only log it when DRY_RUN=1
  if [ "$DRY_RUN" = 1 ]; then log "DRY_RUN: $*"; else "$@"; fi
}

check() {
  raw=$(cat "$TX_FILE") || { log "cannot read $TX_FILE"; exit 1; }
  boot=$(cat "$BOOT_FILE")
  read_state
  # same boot and counter did not go backwards: add the difference;
  # after a reboot the NIC counter restarts at 0, so everything it shows is new
  if [ "$s_boot" = "$boot" ] && [ "$raw" -ge "$s_raw" ]; then
    delta=$((raw - s_raw))
  else
    delta=$raw
  fi

  if [ "$s_month" != "$month" ]; then
    [ -n "$s_month" ] && log "new month $month, last month ($s_month) used $(gib "$s_used")"
    used=$delta; flag=-
    if [ "$s_flag" = stopped ]; then
      act systemctl start "$XRAY_UNIT" && log "new month: started $XRAY_UNIT again"
    fi
  else
    used=$((s_used + delta)); flag=$s_flag
  fi
  save_state

  [ "$used" -lt "$limit" ] && return
  if allowed; then return; fi

  case "$ACTION" in
    stop-xray)
      if [ "$flag" != stopped ]; then
        log "used $(gib "$used") >= ${LIMIT_GIB} GiB for $month: stopping $XRAY_UNIT until next month"
        flag=stopped; save_state
      fi
      # keep it stopped even if something restarts it
      if [ "$DRY_RUN" = 1 ] || systemctl is-active -q "$XRAY_UNIT"; then act systemctl stop "$XRAY_UNIT"; fi
      ;;
    poweroff)
      log "used $(gib "$used") >= ${LIMIT_GIB} GiB for $month: powering off (start it again next month, or run 'egress-cap allow' within 3 min of booting)"
      act systemctl poweroff
      ;;
    *) log "unknown ACTION=$ACTION, doing nothing" ;;
  esac
}

status() {
  read_state
  if [ "$s_month" != "$month" ]; then s_used=0; fi
  echo "month     $month (US Pacific)"
  echo "used      $(gib "$s_used") / ${LIMIT_GIB} GiB  ($(awk -v u="$s_used" -v l="$limit" 'BEGIN{printf "%.1f", 100*u/l}')%)"
  echo "action    $ACTION$( [ "$s_flag" = stopped ] && echo "  [xray stopped by cap]")$(allowed && echo "  [allowed for this month]")"
  echo "counting  $TX_FILE"
}

case "${1:-status}" in
  check)  check ;;
  status) status ;;
  allow)
    mkdir -p "$STATE"; echo "$month" > "$STATE/allow"; log "cap not enforced for the rest of $month"
    read_state
    if [ "$s_month" = "$month" ] && [ "$s_flag" = stopped ]; then
      used=$s_used raw=$s_raw boot=$s_boot flag=-; save_state
      act systemctl start "$XRAY_UNIT" && log "started $XRAY_UNIT again"
    fi ;;
  set)
    [[ "${2:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "usage: egress-cap set GIB" >&2; exit 2; }
    read_state
    used=$(awk -v g="$2" 'BEGIN{printf "%.0f", g*1073741824}')
    raw=$(cat "$TX_FILE"); boot=$(cat "$BOOT_FILE"); flag=$s_flag
    [ "$s_month" = "$month" ] || flag=-
    # back under the cap after being stopped by it: bring xray back
    restart=0; [ "$flag" = stopped ] && [ "$used" -lt "$limit" ] && { flag=-; restart=1; }
    save_state; log "count for $month set to $(gib "$used")"
    [ $restart = 1 ] && act systemctl start "$XRAY_UNIT" && log "under the cap again: started $XRAY_UNIT" ;;
  -h|--help) sed -n '2,11p' "$0" ;;
  *) echo "unknown command: $1 (try --help)" >&2; exit 2 ;;
esac
EGRESS_CAP
chmod 755 /usr/local/sbin/egress-cap

cat > /etc/egress-cap.conf <<EOF
# /etc/egress-cap.conf, read by /usr/local/sbin/egress-cap
# Cap in GiB for the billing month (US Pacific). Standard tier gives 200 GiB
# free per billing account, shared by every VM and project on that account.
LIMIT_GIB=$LIMIT

# What to do at the cap:
#   stop-xray  stop only Xray; SSH keeps working and Xray starts again
#              by itself on the 1st of next month
#   poweroff   shut the VM down; it stays off until you start it in the console
ACTION=$ACTION

XRAY_UNIT=xray
EOF

cat > /etc/systemd/system/egress-cap.service <<'EOF'
[Unit]
Description=Monthly egress cap check (egress-cap)
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/egress-cap check
EOF

cat > /etc/systemd/system/egress-cap.timer <<'EOF'
[Unit]
Description=Run egress-cap check every minute

[Timer]
# 3 minutes after boot gives time to SSH in and run "egress-cap allow"
# if the VM was started again while over the cap
OnBootSec=3min
OnUnitActiveSec=1min
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now egress-cap.timer >/dev/null 2>&1
/usr/local/sbin/egress-cap check
echo "✅ 流量上限已开启：每月 ${LIMIT} GiB，到量后 $( [ "$ACTION" = poweroff ] && echo 关机 || echo '停止 Xray（下月 1 号自动恢复）' )"
/usr/local/sbin/egress-cap status
