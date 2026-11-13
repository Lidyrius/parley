#!/bin/bash
# Started as the container's command. Profile lives in /profile (an encrypted volume on the host).
# VNC password: /profile/.vncpass (made on first start, 0600). CDP: 127.0.0.1:9222 inside,
# forwarded to <container ip>:9223 for the session container on the private network.
set -u
export DISPLAY=:99
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99   # left over after a container restart
Xvfb :99 -screen 0 1440x900x24 -nolisten tcp &
sleep 1; openbox &
[ -s /profile/.vncpass ] || { umask 077; x11vnc -storepasswd "$(head -c 12 /dev/urandom | base64 | tr -dc A-Za-z0-9 | head -c 14)" /profile/.vncpass >/dev/null; }
x11vnc -display :99 -rfbauth /profile/.vncpass -localhost -forever -shared -quiet -rfbport 5900 &
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 >/dev/null 2>&1 &
IP=$(hostname -i | awk '{print $1}')
socat TCP-LISTEN:9223,bind="$IP",fork,reuseaddr TCP:127.0.0.1:9222 &
while true; do
  google-chrome --user-data-dir=/profile/chrome --no-first-run --no-default-browser-check \
    --remote-debugging-port=9222 --disable-sync --window-size=1440,900 \
    --window-position=0,0 https://mail.google.com/
  sleep 3   # closed by hand → back up
done
