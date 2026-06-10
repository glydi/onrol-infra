#!/usr/bin/env bash
# One-command local dev: stand up a user-space Postgres (no Docker, no sudo),
# then build + run the API. Idempotent. Ctrl-C stops the API; Postgres keeps
# running (stop it with: pg_ctl -D "$PGDATA" stop).
#
#   scripts/dev_up.sh            # then, in another shell: scripts/smoke_test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGDATA="${PGDATA:-$ROOT/.pgdata}"
PGPORT="${PGPORT:-5433}"
PGHOST=127.0.0.1

if [ ! -d "$PGDATA/base" ]; then
  echo "[pg] initdb -> $PGDATA"
  initdb -D "$PGDATA" -U "$USER" --auth=trust -E UTF8 >/dev/null
fi

if ! pg_isready -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1; then
  echo "[pg] starting on :$PGPORT"
  pg_ctl -D "$PGDATA" -o "-p $PGPORT -k /tmp" -l "$PGDATA/server.log" start >/dev/null
  for _ in $(seq 1 20); do pg_isready -h "$PGHOST" -p "$PGPORT" >/dev/null 2>&1 && break; sleep 0.3; done
fi
createdb -h "$PGHOST" -p "$PGPORT" -U "$USER" onrol 2>/dev/null && echo "[pg] created db onrol" || echo "[pg] db onrol exists"

# Generate a .env once.
if [ ! -f "$ROOT/.env" ]; then
  echo "[env] writing $ROOT/.env"
  cat > "$ROOT/.env" <<EOF
APP_ENV=development
PORT=8080
DATABASE_URL=postgres://$USER@$PGHOST:$PGPORT/onrol?sslmode=disable
JWT_SECRET=$(openssl rand -hex 32)
JWT_ACCESS_TTL=24h
MAX_DEVICES_PER_USER=2
ATTESTATION_MODE=log
ADMIN_API_KEY=$(openssl rand -hex 16)
ZOHO_WEBINAR_BASE=https://webinar.zoho.in
EOF
fi

echo "[api] building + running on :8080 (Ctrl-C to stop)"
echo "[api] admin key: $(grep ADMIN_API_KEY "$ROOT/.env" | cut -d= -f2)"
cd "$ROOT/backend"
exec go run ./cmd/server
