#!/usr/bin/env bash
# Ship the HTML staff console to the VPS.
#
# It is served from a subfolder of the Flutter web root ($WEB_ROOT/admin/) so the
# EXISTING nginx `location /` (try_files) serves it as real static files — no nginx
# change needed, and it works at https://lms.<host>/admin/ . The Flutter web deploy
# (scripts/deploy.sh web) excludes 'admin/' from its --delete, so shipping the app
# never wipes the console.
set -euo pipefail
HOST="${HOST:-root@187.127.178.100}"
BASE="${BASE:-https://lms.187-127-178-100.sslip.io}"
DEST="${DEST:-/var/www/onrol/admin/}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Syncing admin-web → $HOST:$DEST"
ssh "$HOST" "mkdir -p $DEST"
rsync -az --delete -e ssh \
  --exclude 'README.md' --exclude 'deploy.sh' \
  "$ROOT/admin-web/" "$HOST:$DEST"

echo "==> Verify (expect a JS content-type, not text/html)"
curl -s -o /dev/null -w "  /admin/          -> %{http_code} %{content_type}\n" "$BASE/admin/"
curl -s -o /dev/null -w "  /admin/core.js   -> %{http_code} %{content_type}\n" "$BASE/admin/core.js"
echo "==> Done — $BASE/admin/"
