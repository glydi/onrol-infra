#!/usr/bin/env bash
# Ship the HTML staff console to the VPS. The nginx /admin/ location is already
# installed on onrol-lms; this only syncs the static files (its own web root, so
# the Flutter `deploy.sh web --delete` never touches it).
set -euo pipefail
HOST="${HOST:-root@187.127.178.100}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> Syncing admin-web → $HOST:/var/www/onrol-admin/"
rsync -az --delete -e ssh \
  --exclude 'README.md' --exclude 'deploy.sh' \
  "$ROOT/admin-web/" "$HOST:/var/www/onrol-admin/"

echo "==> Verify"
curl -s -o /dev/null -w "  /admin/ -> %{http_code}\n" https://lms.187-127-178-100.sslip.io/admin/
echo "==> Done — https://lms.187-127-178-100.sslip.io/admin/"
