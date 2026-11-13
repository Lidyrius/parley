#!/bin/bash
# Brings the pilot back after a server reboot. Runs as root on the host from a root-owned copy
# (/opt/parley-pilot/autostart.sh, never from the container's writable home):
#   autostart.sh               start the pilot container, Parley's daemon and the keep-alive;
#                              each browser only if its encrypted volume is open
#   autostart.sh unlock <name> LUKS key on stdin: open + mount browser-<name>'s volume, then as above
#   autostart.sh install       copy itself to /opt/parley-pilot and enable parley-pilot.service
# Inside the container (as sydney) `autostart.sh sessions` starts the two tmux sessions if missing.
# A browser whose volume is closed stays off: Chrome would otherwise write a fresh, unencrypted
# profile into the empty mount point. Its keep-alive check then reports "Browser FEHLER".
set -u
P=/opt/parley-pilot
R=/Users/sydney/workspace/privat/vloude
case "${1:-}" in
  sessions)
    tmux has-session -t =parley 2>/dev/null || tmux new-session -d -s parley -x 200 -y 50 \
      "PARLEY_CLAUDE_CMD=claude PARLEY_CALLBACK_WAIT_SECONDS=0 bash -lc 'dotnet $R/linux/bin/Release/net8.0/parley.dll run'"
    tmux has-session -t =keepalive 2>/dev/null || tmux new-session -d -s keepalive "bash -lc '$R/linux/pilot/keepalive.sh run'"
    tmux ls; exit ;;
  install)
    install -m 0700 -o root -g root "$0" "$P/autostart.sh"
    cat > /etc/systemd/system/parley-pilot.service <<EOF
[Unit]
Description=Parley pilot: container, daemon, keep-alive (browsers only with an open volume)
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$P/autostart.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable parley-pilot.service; exit ;;
  unlock)
    n="${2:?name: dev, saf or privat}"
    mountpoint -q "$P/browser-$n" || {
      cryptsetup open --key-file=- "$P/browser-$n.img" "parley-browser-$n" && mount "/dev/mapper/parley-browser-$n" "$P/browser-$n"
    } || exit 1 ;;
esac
docker start parley-pilot >/dev/null || exit 1
for n in dev saf privat; do
  if mountpoint -q "$P/browser-$n"; then docker start "parley-browser-$n" >/dev/null && echo "browser-$n: läuft"
  else echo "browser-$n: Volume zu — nicht gestartet (autostart.sh unlock $n < Schlüssel)"; fi
done
docker exec -u sydney parley-pilot bash "$R/linux/pilot/autostart.sh" sessions
