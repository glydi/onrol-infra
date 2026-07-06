#!/usr/bin/env bash
# r2_gc.sh — garbage-collect the R2 bucket so it holds ONLY the video store.
#
# The database is the source of truth: every media_assets row references one
# source object (videos/<object_key>) and one HLS folder (videos/<id>/…).
# Anything else under the bucket — orphaned HLS folders, orphaned source mp4s,
# stray root uploads left by aborted/superseded transcodes — is deleted. Nothing
# is hard-coded, so this stays correct as videos come and go.
#
# db-backups/ is NOT a video: it's the nightly Postgres backup history. It is
# LEFT ALONE by default. Pass --include-backups only if you really want it gone
# (note: the backup cron will just write a fresh dump the next night).
#
# Reads R2_* creds from ./.env or /opt/onrol/.env (same as scripts/r2.sh) and
# the keep-set from Postgres, so run it where both are reachable (the VPS).
# Dry-run by default; pass --apply to actually delete.
#
# Usage:
#   scripts/r2_gc.sh                        # dry run — show what WOULD be deleted
#   scripts/r2_gc.sh --apply                # delete orphans, keep db-backups/
#   scripts/r2_gc.sh --apply --include-backups
set -euo pipefail

APPLY=0; INCLUDE_BACKUPS=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --include-backups) INCLUDE_BACKUPS=1 ;;
    -h|--help) grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

# Load .env (first match wins) for R2 creds.
for f in ./.env /opt/onrol/.env "$(dirname "$0")/../.env"; do
  [ -f "$f" ] && { set -a; . "$f"; set +a; break; }
done
: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID}"; : "${R2_BUCKET:?set R2_BUCKET}"
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
export AWS_DEFAULT_REGION=auto AWS_EC2_METADATA_DISABLED=true
EP="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"; B="$R2_BUCKET"
command -v aws >/dev/null || { echo "aws CLI not found"; exit 1; }

PSQL=(sudo -u postgres psql onrol -At)

# --- KEEP set, straight from the database ---------------------------------
mapfile -t KEEP_IDS < <("${PSQL[@]}" -c "SELECT id FROM media_assets WHERE id IS NOT NULL;")
mapfile -t KEEP_MP4 < <("${PSQL[@]}" -c "SELECT object_key FROM media_assets WHERE COALESCE(object_key,'')<>'';")
echo "video store (DB): ${#KEEP_IDS[@]} assets, ${#KEEP_MP4[@]} source objects"

is_kept() {
  local k="$1" id m
  for m in "${KEEP_MP4[@]}"; do [ "$k" = "$m" ] && return 0; done
  for id in "${KEEP_IDS[@]}"; do case "$k" in "videos/$id/"*) return 0;; esac; done
  return 1
}

hr() { numfmt --to=iec "$1" 2>/dev/null || echo "${1}B"; }

# --- walk the whole bucket -------------------------------------------------
DEL=$(mktemp); : > "$DEL"
del_bytes=0; del_n=0; keep_n=0; bak_n=0
while read -r _d _t size key; do
  [ -z "${key:-}" ] && continue
  case "$key" in
    db-backups/*)
      if [ "$INCLUDE_BACKUPS" -eq 1 ]; then echo "$key" >> "$DEL"; del_n=$((del_n+1)); del_bytes=$((del_bytes+size))
      else bak_n=$((bak_n+1)); fi
      continue ;;
  esac
  if is_kept "$key"; then keep_n=$((keep_n+1))
  else echo "$key" >> "$DEL"; del_n=$((del_n+1)); del_bytes=$((del_bytes+size)); fi
done < <(aws s3 ls "s3://$B/" --recursive --endpoint-url "$EP")

echo "keep: $keep_n objects | db-backups left: $bak_n | DELETE: $del_n objects ($(hr "$del_bytes"))"
echo "---- delete set (collapsed) ----"
sed -E 's#^(videos/[^/]+/).*#\1#' "$DEL" | sort | uniq -c | sort -rn

if [ "$del_n" -eq 0 ]; then echo "nothing to delete — bucket already clean ✓"; rm -f "$DEL"; exit 0; fi
if [ "$APPLY" -ne 1 ]; then echo; echo "DRY RUN — re-run with --apply to delete the above."; rm -f "$DEL"; exit 0; fi

# --- delete, batched (delete-objects takes up to 1000 keys/call) -----------
echo "deleting…"
split -l 900 "$DEL" "$DEL.part."
for part in "$DEL".part.*; do
  keys_json=$(awk 'BEGIN{printf "["} {gsub(/\\/,"\\\\");gsub(/"/,"\\\"");printf "%s{\"Key\":\"%s\"}",(NR>1?",":""),$0} END{printf "]"}' "$part")
  aws s3api delete-objects --bucket "$B" --endpoint-url "$EP" \
    --delete "{\"Objects\":$keys_json,\"Quiet\":true}" >/dev/null
  echo "  removed $(wc -l < "$part") objects"
done
rm -f "$DEL" "$DEL".part.*
if [ "$INCLUDE_BACKUPS" -eq 1 ]; then echo "done ✓ — R2 now holds only the video store"
else echo "done ✓ — R2 now holds only the video store + db-backups/"; fi
