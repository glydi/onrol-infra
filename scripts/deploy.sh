#!/usr/bin/env bash
# =============================================================================
# Push local edits to the live VPS — backend binary + Flutter web, in one shot.
#
#   bash scripts/deploy.sh            # build + ship API + web + landing, verify
#   bash scripts/deploy.sh backend    # only the Go API
#   bash scripts/deploy.sh web        # only the Flutter web app
#   bash scripts/deploy.sh landing    # only the apex landing page
#
# The machine running this is expected to already have SSH access to the VPS
# (key accepted) — no password prompts.
#
# Override the target if needed:
#   HOST=root@1.2.3.4 WEB_ROOT=/var/www/onrol bash scripts/deploy.sh
# =============================================================================
set -euo pipefail

HOST="${HOST:-root@187.127.178.100}"
APP_DIR="${APP_DIR:-/opt/onrol}"
WEB_ROOT="${WEB_ROOT:-/var/www/onrol}"
LANDING_ROOT="${LANDING_ROOT:-/var/www/onrol-landing}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHAT="${1:-all}"

# Make flutter visible if it's only on PATH via a local SDK checkout.
command -v flutter >/dev/null || export PATH="$PATH:$HOME/flutter/bin:/opt/flutter/bin"

log() { printf '\n\033[1;36m==>\033[0m \033[1m%s\033[0m\n' "$*"; }

deploy_backend() {
  log "Building API (linux/amd64)"
  ( cd "$ROOT/backend" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -trimpath -ldflags="-s -w" -o /tmp/onrol-server-linux ./cmd/server )
  local LOCAL_MD5
  LOCAL_MD5="$(md5sum /tmp/onrol-server-linux | awk '{print $1}')"
  log "Shipping API → $HOST"
  scp -o ConnectTimeout=10 /tmp/onrol-server-linux "$HOST:$APP_DIR/onrol-server.new"
  # Stop BEFORE swapping: replacing a running binary in place races with the
  # restart ("Text file busy", exit 203/EXEC) and can leave a stale binary.
  ssh "$HOST" "set -e
    systemctl stop onrol.service
    install -m 0755 -o onrol -g onrol $APP_DIR/onrol-server.new $APP_DIR/onrol-server
    rm -f $APP_DIR/onrol-server.new
    systemctl start onrol.service
    sleep 2
    systemctl is-active onrol.service >/dev/null || { echo 'service failed to start'; journalctl -u onrol -n 20 --no-pager; exit 1; }
    REMOTE_MD5=\$(md5sum $APP_DIR/onrol-server | awk '{print \$1}')
    [ \"\$REMOTE_MD5\" = \"$LOCAL_MD5\" ] || { echo \"binary md5 mismatch: local=$LOCAL_MD5 remote=\$REMOTE_MD5\"; exit 1; }
    printf 'API md5 MATCH ✓ + healthz: '; curl -fsS http://127.0.0.1:8080/healthz; echo"
}

deploy_web() {
  log "Building web app"
  ( cd "$ROOT/app" && flutter build web --release --no-tree-shake-icons --pwa-strategy=none >/dev/null )
  log "Publishing web → $HOST:$WEB_ROOT (with timestamped backup)"
  ssh "$HOST" "cp -a $WEB_ROOT $WEB_ROOT.bak-\$(date +%Y%m%d-%H%M%S) 2>/dev/null || true"
  rsync -az --delete -e ssh "$ROOT/app/build/web/" "$HOST:$WEB_ROOT/"
  local L R
  L="$(md5sum "$ROOT/app/build/web/main.dart.js" | awk '{print $1}')"
  R="$(ssh "$HOST" "md5sum $WEB_ROOT/main.dart.js | awk '{print \$1}'")"
  if [ "$L" = "$R" ]; then echo "web md5 MATCH ✓ ($L)"; else echo "web md5 MISMATCH ✗  local=$L remote=$R"; exit 1; fi
}

deploy_landing() {
  log "Publishing landing → $HOST:$LANDING_ROOT"
  ssh "$HOST" "mkdir -p $LANDING_ROOT"
  rsync -az -e ssh "$ROOT/deploy/landing/" "$HOST:$LANDING_ROOT/"
  local L R
  L="$(md5sum "$ROOT/deploy/landing/index.html" | awk '{print $1}')"
  R="$(ssh "$HOST" "md5sum $LANDING_ROOT/index.html | awk '{print \$1}'")"
  if [ "$L" = "$R" ]; then echo "landing md5 MATCH ✓ ($L)"; else echo "landing md5 MISMATCH ✗  local=$L remote=$R"; exit 1; fi
}

case "$WHAT" in
  all)     deploy_backend; deploy_web; deploy_landing ;;
  backend) deploy_backend ;;
  web)     deploy_web ;;
  landing) deploy_landing ;;
  *) echo "usage: deploy.sh [all|backend|web|landing]" >&2; exit 1 ;;
esac

log "Deployed. (hard-refresh / incognito to clear the service-worker cache)"
