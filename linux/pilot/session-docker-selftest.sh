#!/bin/bash
# Checks session-docker.sh's fences, as root on the host. Read-only towards the production daemon
# (it only counts its containers). Leaves nothing behind but pulled images in the sessions' daemon.
#   session-docker-selftest.sh [--mssql]   --mssql: also an EMPTY MS SQL Server (random password)
set -uo pipefail
pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
in_pilot() { docker exec -u sydney parley-pilot bash -lc "$1"; }
sd() { in_pilot "docker $1"; }   # the sessions' docker

echo "Isolation"
prod="$(docker ps -q | wc -l)"
mine="$(sd 'ps -aq' | wc -l)"
seen="$(sd "ps -a --format '{{.Names}}'" | grep -cxFf <(docker ps --format '{{.Names}}') || true)"
[ "$seen" = 0 ] && ok "sessions' docker sees none of the $prod production containers (has $mine own)" || bad "sees $seen production containers"
check "no host docker socket in the pilot" in_pilot '! test -e /var/run/docker.sock'
# the production daemon's socket is hidden from the sessions' daemon: mounting the path gives an inaccessible node
check "host socket unusable from a container" in_pilot '! docker run --rm -v /var/run/docker.sock:/s alpine:3.20 sh -c "apk add -q curl >/dev/null 2>&1 && curl -fsS -m 5 --unix-socket /s http://x/_ping"'
# as close to --privileged as it goes: every capability, no seccomp, no AppArmor, host / mounted
ESC='run --rm --cap-add ALL --security-opt seccomp=unconfined --security-opt apparmor=unconfined -v /:/host alpine:3.20'
out="$(sd "$ESC sh -c 'cat /proc/self/uid_map | head -1; ls -A /host/srv | wc -l; ls -A /host/root | wc -l; ls -A /host/home | wc -l; cat /host/etc/shadow 2>&1 | head -1; touch /host/etc/parley-escape-test 2>&1; touch /host/usr/parley-escape-test 2>&1; mknod /host/tmp/sda b 8 0 2>&1; ls /host/var/lib/docker 2>&1 | head -1'" 2>&1)"
echo "$out" | sed 's/^/        /'
[ "$(echo "$out" | sed -n 1p | awk '{print $2}')" = 1500 ] && ok "container root = host uid 1500 (uid_map)" || bad "container root is not uid 1500 on the host"
[ "$(echo "$out" | sed -n 2p)" = 0 ] && ok "all caps + host /: /srv (production compose files) is empty" || bad "/srv visible"
[ "$(echo "$out" | sed -n 3p)" = 0 ] && [ "$(echo "$out" | sed -n 4p)" = 0 ] && ok "all caps + host /: /root and /home are empty" || bad "/root or /home visible"
echo "$out" | grep -q "shadow.*Permission denied" && echo "$out" | grep -q "usr/parley-escape-test.*Permission denied" && [ ! -e /etc/parley-escape-test ] && [ ! -e /usr/parley-escape-test ] && ok "all caps: host /etc/shadow unreadable, /etc and /usr unchanged (an /etc write lands in rootlesskit's private copy)" || { bad "host root files reachable"; rm -f /etc/parley-escape-test /usr/parley-escape-test; }
priv="$(sd 'run --rm --privileged alpine:3.20 true' 2>&1)"; [ -n "$priv" ] && ok "--privileged is refused (read-only sysfs of the pilot network) — fails closed" || bad "--privileged ran"
ps_out="$(sd "run --rm --pid=host alpine:3.20 ps -o user=")"; n="$(echo "$ps_out" | grep -vcE "^(1500|root)$" || true)"
[ -n "$ps_out" ] && [ "$n" = 0 ] && ok "--pid=host shows no processes of other users" || bad "--pid=host shows $n foreign processes"

echo "Limits"
systemctl show parley-docker -p MemoryMax -p CPUQuotaPerSecUSec -p TasksMax | sed 's/^/        /'
ev=/sys/fs/cgroup/system.slice/parley-docker.service/memory.events
k1="$(awk '/^oom_kill /{print $2}' $ev)"
sd 'run --rm alpine:3.20 sh -c "apk add -q stress-ng >/dev/null 2>&1 && stress-ng --vm 1 --vm-bytes 12G --vm-keep -t 25 >/dev/null 2>&1"' >/dev/null 2>&1
k2="$(awk '/^oom_kill /{print $2}' $ev)"; peak="$(systemctl show parley-docker -p MemoryPeak --value 2>/dev/null)"
[ "$k2" -gt "$k1" ] && [ "$peak" -le $((8*1024*1024*1024 + 64*1024*1024)) ] && ok "12 GB in a container: killed at the 8 GB cap ($((k2-k1)) OOM kill(s), peak $((peak/1024/1024)) MiB)" || bad "memory cap (kills $k1→$k2, peak $peak)"
sd 'run -d --rm --name parley-cputest alpine:3.20 sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do yes >/dev/null & done; sleep 20"' >/dev/null
sleep 12
t1="$(systemctl show parley-docker -p CPUUsageNSec --value)"; sleep 5; t2="$(systemctl show parley-docker -p CPUUsageNSec --value)"
cores=$(( (t2 - t1) / 50000000 ))   # per cent of one core over 5 s
sd 'rm -f parley-cputest' >/dev/null 2>&1
[ "$cores" -gt 150 ] && [ "$cores" -le 420 ] && ok "10 busy loops use ${cores} % CPU (cap 400 %, the host has $(nproc) threads)" || bad "CPU ${cores} % over the cap"

echo "Disk"
df -h --output=size,used,avail /opt/parley-docker/data | tail -1 | sed 's/^/        data image: /'
root_dir="$(sd "info --format {{.DockerRootDir}}")"; [ "$root_dir" = /opt/parley-docker/data/docker ] && ok "images and volumes on the capped image ($root_dir)" || bad "data root $root_dir"

echo "Network"
sd 'run -d --rm --name parley-nettest -p 18080:80 -p 0.0.0.0:18081:80 nginx:alpine' >/dev/null && sleep 3
check "pull + DNS work (nginx image)" in_pilot 'docker image inspect nginx:alpine'
check "-p 18080: reachable from the session (pilot loopback)" in_pilot 'curl -fsS -m 5 -o /dev/null http://127.0.0.1:18080'
check "-p 18080: not on the host's loopback" bash -c '! curl -fsS -m 3 -o /dev/null http://127.0.0.1:18080'
check "no session port on any host interface" bash -c '! ss -ltnH | grep -qE ":1808[01]\b"'
pub="$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 | grep -vE '^(10|172|100)\.' | head -1)"
check "-p 0.0.0.0:18081 not on the public address $pub" bash -c "! curl -fsS -m 3 -o /dev/null http://$pub:18081"
sd 'rm -f parley-nettest' >/dev/null 2>&1

if [ "${1:-}" = --mssql ]; then
  echo "MS SQL Server, empty (no customer data, random password)"
  pw="Pt$(head -c 18 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 18)9!"
  in_pilot "mkdir -p ~/mssql-test && cd ~/mssql-test && cat > compose.yml <<'EOF'
services:
  mssql:
    image: mcr.microsoft.com/mssql/server:2022-latest
    environment: { ACCEPT_EULA: \"Y\", MSSQL_PID: Developer, MSSQL_SA_PASSWORD: \"\${MSSQL_SA_PASSWORD}\" }
    ports: [\"127.0.0.1:14333:1433\"]
    volumes: [\"mssql-data:/var/opt/mssql\"]
volumes: { mssql-data: {} }
EOF
MSSQL_SA_PASSWORD='$pw' docker compose up -d --quiet-pull 2>&1 | tail -1"
  for _ in $(seq 1 60); do in_pilot "cd ~/mssql-test && docker compose logs mssql 2>&1 | grep -q 'Recovery is complete'" && break; sleep 3; done
  r="$(in_pilot "cd ~/mssql-test && docker compose exec -T mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P '$pw' -h -1 -Q \"SET NOCOUNT ON; CREATE DATABASE parley_test; SELECT CAST(SERVERPROPERTY('ProductVersion') AS varchar(20)) + ' ' + DB_NAME(DB_ID('parley_test'))\"" 2>&1)"
  echo "        $r"
  echo "$r" | grep -q parley_test && ok "MS SQL 2022 runs, database created" || bad "MS SQL"
  check "MS SQL port reachable from the session at 127.0.0.1:14333" in_pilot 'timeout 3 bash -c "</dev/tcp/127.0.0.1/14333"'
  in_pilot 'cd ~/mssql-test && docker compose down -v 2>&1 | tail -1 && cd && rm -rf ~/mssql-test' >/dev/null
fi

echo "Result: $pass ok, $fail failed"
[ $fail = 0 ]
