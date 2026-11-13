#!/bin/bash
# Docker for the pilot's sessions on the server: a rootless Docker daemon of its own, as uid 1500
# (the pilot's user) on the host — never the production daemon, which this leaves alone. Root on
# the host (root-owned copy at /opt/parley-docker/session-docker.sh):
#   session-docker.sh install   once: uidmap, user parley-sessions (1500), subuids, data volume, unit
#   session-docker.sh start     (re)start unless it already runs in the pilot's network; autostart.sh
#                               calls it at boot, parley-docker-follow.service after every pilot start
#   session-docker.sh stop | status
#   session-docker.sh selftest  isolation, limits and function checks (see docs/SERVER-HOST.md)
# How it is fenced in:
#   - its socket is the only way in: /Users/sydney/.docker-rootless/docker.sock in the pilot
#     (DOCKER_HOST there); the production daemon's socket is not mounted anywhere near it
#   - root in a session's container is uid 1500 on the host (user namespace), --privileged included
#   - it sees a trimmed file system: /srv, /home, /root, /opt (but ours), /var/lib, /var/log, /mnt,
#     /media, /snap and the files in / are hidden; other users' processes are invisible
#   - it lives in the pilot container's network namespace: `-p 127.0.0.1:x:y` lands on the
#     pilot's loopback, where the sessions are; nothing is published on the host
#   - one cgroup with caps for all its containers: RAM, CPU, tasks; low CPU/IO weight
#   - its data sits on a size-capped file system image (/opt/parley-docker/data.img)
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "as root" >&2; exit 1; }
D=/opt/parley-docker; U=parley-sessions; ID=1500
PH=/opt/parley-pilot/home                       # the pilot's /Users/sydney
SIZE="${PARLEY_DOCKER_SIZE:-40G}" MEM="${PARLEY_DOCKER_MEM:-8G}" CPU="${PARLEY_DOCKER_CPU:-400%}"
NS=parley-pilot

install_() {
  dpkg -s uidmap >/dev/null 2>&1 || apt-get install -y --no-install-recommends --no-upgrade uidmap
  getent passwd $ID >/dev/null || { groupadd -g $ID $U 2>/dev/null || true; useradd -r -u $ID -g $ID -M -d $D/home -s /usr/sbin/nologin $U; }
  grep -q "^$U:" /etc/subuid || echo "$U:1500000:65536" >> /etc/subuid
  grep -q "^$U:" /etc/subgid || echo "$U:1500000:65536" >> /etc/subgid
  mkdir -p $D/data $D/home/.config/docker $D/run
  [ -f $D/data.img ] || { truncate -s "$SIZE" $D/data.img; mkfs.ext4 -q -L parley-docker $D/data.img; }
  cat > $D/home/.config/docker/daemon.json <<'EOF'
{ "ip": "127.0.0.1", "exec-opts": ["native.cgroupdriver=cgroupfs"],
  "log-driver": "json-file", "log-opts": { "max-size": "20m", "max-file": "3" },
  "features": { "buildkit": true } }
EOF
  chown -R $ID:$ID $D/home $D/run; chmod 700 $D/run; chmod 755 $D
  install -m 0700 -o root -g root "$0" $D/session-docker.sh
  cat > /etc/systemd/system/parley-docker.service <<EOF
[Unit]
Description=Rootless Docker for the Parley pilot's sessions (uid $ID; not the production daemon)
After=network-online.target

[Service]
User=$U
Group=$U
Environment=HOME=$D/home XDG_RUNTIME_DIR=$D/run PATH=/usr/bin:/usr/sbin:/bin:/sbin
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_NET=slirp4netns DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=builtin DOCKERD_ROOTLESS_ROOTLESSKIT_MTU=65520
Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_FLAGS="--pidns --cgroupns --evacuate-cgroup2=daemon"
ExecStart=/usr/bin/dockerd-rootless.sh --data-root $D/data/docker -H unix:///Users/sydney/.docker-rootless/docker.sock
Restart=on-failure
RestartSec=5
# the pilot's network: published ports land where the sessions are, never on the host
NetworkNamespacePath=/run/netns/$NS
# limits for everything it runs
Delegate=yes
MemoryMax=$MEM
MemorySwapMax=0
CPUQuota=$CPU
CPUWeight=50
IOWeight=50
TasksMax=4096
# what it may see of the host
PrivateTmp=yes
ProtectHome=tmpfs
ProtectProc=invisible
TemporaryFileSystem=/srv /opt /var/lib /var/log /var/backups /mnt /media /snap /Users
BindPaths=$D $PH:/Users/sydney
BindReadOnlyPaths=/run/systemd/resolve/resolv.conf:/etc/resolv.conf
InaccessiblePaths=-/run/docker.sock -/run/containerd -/run/docker -/installimage.conf -/installimage.debug -/mc.zip

[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/parley-docker-follow.service <<EOF
[Unit]
Description=Restart the sessions' rootless Docker whenever the pilot container starts
After=docker.service
[Service]
ExecStart=$D/session-docker.sh follow
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now parley-docker-follow.service
  # the client in the pilot: the host's own docker CLI and plugins (static binaries), DOCKER_HOST
  install -d -o $ID -g $ID $PH/.local/bin $PH/.docker $PH/.docker/cli-plugins
  install -o $ID -g $ID -m 755 /usr/bin/docker $PH/.local/bin/docker
  for p in docker-compose docker-buildx; do
    [ -x /usr/libexec/docker/cli-plugins/$p ] && install -o $ID -g $ID -m 755 /usr/libexec/docker/cli-plugins/$p $PH/.docker/cli-plugins/$p
  done
  grep -q 'docker-rootless/docker.sock' $PH/.profile 2>/dev/null || {
    echo 'export DOCKER_HOST=unix:///Users/sydney/.docker-rootless/docker.sock   # rootless Docker for sessions (session-docker.sh)' >> $PH/.profile
    chown $ID:$ID $PH/.profile; }
  echo "installed. start: $D/session-docker.sh start (after the pilot container runs)"
}

start() {
  mountpoint -q $D/data || mount -o loop,noatime $D/data.img $D/data
  mkdir -p $D/data/docker; chown $ID:$ID $D/data $D/data/docker; chmod 700 $D/data
  install -d -o $ID -g $ID -m 700 $PH/.docker-rootless
  local pid; pid="$(docker inspect -f '{{.State.Pid}}' parley-pilot)"
  [ "$pid" -gt 0 ] || { echo "pilot container not running" >&2; exit 1; }
  # already running in the pilot's current network namespace: nothing to do
  if systemctl is-active -q parley-docker && [ -e /run/netns/$NS ] \
     && [ "$(stat -L -c %i /run/netns/$NS)" = "$(stat -L -c %i /proc/$pid/ns/net)" ]; then
    echo "already running in the pilot's network"; return
  fi
  ip netns delete $NS 2>/dev/null || true
  ip netns attach $NS "$pid"
  systemctl restart parley-docker
  for _ in $(seq 1 30); do
    [ -S $PH/.docker-rootless/docker.sock ] && docker exec -u sydney parley-pilot bash -lc 'docker info --format "{{.ServerVersion}} rootless={{range .SecurityOptions}}{{.}} {{end}}"' 2>/dev/null && return
    sleep 1
  done
  echo "parley-docker did not come up:" >&2; journalctl -u parley-docker -n 20 --no-pager >&2; exit 1
}

# parley-docker-follow.service: every start of the pilot container (a new network namespace) →
# start again. Only reads the production daemon's event stream; changes nothing there.
follow() {
  docker events --filter type=container --filter "container=${PARLEY_FOLLOW_CONTAINER:-parley-pilot}" --filter event=start --format '{{.Actor.Attributes.name}}' |
    while read -r name; do echo "$name started"; sleep 2; "$D/session-docker.sh" start || echo "start failed"; done
}

stop() { systemctl stop parley-docker; ip netns delete $NS 2>/dev/null || true; }

status() {
  systemctl is-active parley-docker || true
  systemctl show parley-docker -p MemoryCurrent -p MemoryMax -p CPUQuotaPerSecUSec -p TasksCurrent | tr '\n' ' '; echo
  df -h --output=size,used,avail $D/data 2>/dev/null | tail -1 | sed 's/^/data: /'
}

case "${1:-}" in
  install) install_ ;; start) start ;; stop) stop ;; status) status ;; follow) follow ;;
  selftest) exec bash "$(dirname "$0")/session-docker-selftest.sh" ;;
  *) sed -n '2,19p' "$0"; exit 2 ;;
esac
