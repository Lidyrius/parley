#!/bin/bash
# Pilot build/test helper — the ONLY way the porting work touches the server.
# Everything it does stays inside the throwaway container `parley-pilot` and its
# data folder /opt/parley-pilot/home on the server. Nothing else on the server is touched.
#
#   pilot-build.sh sync              copy the repo's working tree (git-visible files only) to the container
#   pilot-build.sh linux             sync, then build linux/ for linux-x64
#   pilot-build.sh windows           sync, then compile the Windows app on Linux (EnableWindowsTargeting) as a regression check
#   pilot-build.sh exec <cmd...>     run a command in the container as the pilot user, cwd = repo root
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOST="${PARLEY_PILOT_HOST:?set PARLEY_PILOT_HOST to the ssh alias of the pilot server}"
DST="${PARLEY_PILOT_DST:-/opt/parley-pilot/home${REPO#/Users/sydney}}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15)

sync() {
  cd "$REPO"
  # Only what git sees (tracked + untracked-not-ignored): no .env, no secrets*, no private notes.
  # linux/ sources are replaced wholesale so deleted files disappear; build output (bin/obj) stays.
  "${SSH[@]}" "$HOST" "mkdir -p $DST/linux && find $DST/linux -type f ! -path '*/bin/*' ! -path '*/obj/*' -delete"
  git ls-files -co --exclude-standard -z \
    | grep -zvE '^(ios/|android/|docs/design/|docs/logo/|\.playwright-mcp/)|\.privat\.md$' \
    | while IFS= read -r -d '' f; do [ -f "$f" ] && printf '%s\0' "$f"; done \
    | COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --null -T - -cf - 2>/dev/null \
    | "${SSH[@]}" "$HOST" "tar -xf - -C $DST --no-same-owner --warning=no-unknown-keyword && chown -R 1500:1500 $DST"
}

inbox() {
  local q; q=$(printf '%q ' "$@")
  "${SSH[@]}" "$HOST" "docker exec -u sydney -w $REPO parley-pilot bash -lc $(printf '%q' "$q")"
}

case "${1:-}" in
  sync) sync ;;
  linux) sync; inbox bash -c 'cd linux && dotnet build -c Release --nologo -v q 2>&1 | tail -80' ;;
  windows) sync; inbox bash -c 'cd windows && dotnet build Parley.Win.csproj -c Release -p:EnableWindowsTargeting=true -r win-x64 --nologo -v q -o /tmp/winbuild 2>&1 | tail -80' ;;
  exec) shift; inbox "$@" ;;
  *) echo "usage: $0 sync|linux|windows|exec <cmd...>"; exit 2 ;;
esac
