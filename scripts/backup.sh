#!/usr/bin/env bash
# Nightly Postgres backup -> gzip -> (optional) Cloudflare R2.
# Wire into cron:  0 2 * * *  /opt/onrol/scripts/backup.sh >> /var/log/onrol-backup.log 2>&1
#
# At 100-300 users this is your REAL resilience story (see ARCHITECTURE.md §2.5).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ -f "$ROOT/.env" ] && set -a && . "$ROOT/.env" && set +a

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="${BACKUP_DIR:-$ROOT/backups}"
mkdir -p "$OUT_DIR"
OUT_FILE="$OUT_DIR/onrol-$STAMP.sql.gz"

echo "[backup] dumping to $OUT_FILE"
# Dump from inside the compose network if running there; falls back to DATABASE_URL.
if command -v docker >/dev/null 2>&1 && docker compose ps postgres >/dev/null 2>&1; then
  docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$OUT_FILE"
else
  pg_dump "$DATABASE_URL" | gzip > "$OUT_FILE"
fi
echo "[backup] wrote $(du -h "$OUT_FILE" | cut -f1)"

# Optional offsite copy to R2 (needs awscli configured for the R2 endpoint).
if [ -n "${R2_BUCKET:-}" ] && command -v aws >/dev/null 2>&1; then
  aws s3 cp "$OUT_FILE" "s3://$R2_BUCKET/db-backups/" \
    --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  echo "[backup] uploaded to R2"
fi

# Retain 14 days locally.
find "$OUT_DIR" -name 'onrol-*.sql.gz' -mtime +14 -delete
echo "[backup] done"

# Restore (manual):
#   gunzip < onrol-YYYYMMDD-HHMMSS.sql.gz | psql "$DATABASE_URL"
