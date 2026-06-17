#!/usr/bin/env bash
# r2.sh — thin CLI wrapper around the AWS CLI, pointed at Cloudflare R2 (S3 API).
#
# Reads R2_ACCOUNT_ID + R2_BUCKET (and optional R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY)
# from the environment or ./.env or /opt/onrol/.env, so you never type the endpoint.
# R2 region is always "auto".
#
# Requires the AWS CLI:  brew install awscli   (or: pip install awscli)
# Auth: either set R2_ACCESS_KEY_ID + R2_SECRET_ACCESS_KEY in .env, or `aws configure`
#       with your R2 API token's Access Key ID + Secret.
#
# Usage:
#   scripts/r2.sh ls [prefix]            # list objects
#   scripts/r2.sh up <file> [key]        # upload a file (key defaults to basename)
#   scripts/r2.sh rm <key>               # delete an object
#   scripts/r2.sh url <key>              # print the public URL (needs R2_PUBLIC_BASE)
#   scripts/r2.sh head <key>            # show object metadata (size, type)
set -euo pipefail

# Load .env if present (first match wins).
for f in ./.env /opt/onrol/.env "$(dirname "$0")/../.env"; do
  [ -f "$f" ] && { set -a; . "$f"; set +a; break; }
done

: "${R2_ACCOUNT_ID:?set R2_ACCOUNT_ID (in .env or env)}"
: "${R2_BUCKET:?set R2_BUCKET (in .env or env)}"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# Prefer R2_* creds; fall back to whatever the AWS CLI already has configured.
export AWS_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
export AWS_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
export AWS_DEFAULT_REGION=auto
export AWS_EC2_METADATA_DISABLED=true

command -v aws >/dev/null || { echo "aws CLI not found — install it: brew install awscli"; exit 1; }

cmd="${1:-help}"; shift || true
case "$cmd" in
  ls)
    aws s3 ls "s3://${R2_BUCKET}/${1:-}" --endpoint-url "$ENDPOINT" ;;
  up|upload)
    f="${1:?usage: r2.sh up <file> [key]}"; key="${2:-$(basename "$f")}"
    aws s3 cp "$f" "s3://${R2_BUCKET}/${key}" --endpoint-url "$ENDPOINT"
    echo "uploaded → ${key}"
    [ -n "${R2_PUBLIC_BASE:-}" ] && echo "public URL: ${R2_PUBLIC_BASE%/}/${key}" ;;
  rm)
    aws s3 rm "s3://${R2_BUCKET}/${1:?usage: r2.sh rm <key>}" --endpoint-url "$ENDPOINT" ;;
  head)
    aws s3api head-object --bucket "$R2_BUCKET" --key "${1:?usage: r2.sh head <key>}" --endpoint-url "$ENDPOINT" ;;
  url)
    key="${1:?usage: r2.sh url <key>}"
    if [ -n "${R2_PUBLIC_BASE:-}" ]; then echo "${R2_PUBLIC_BASE%/}/${key}";
    else echo "set R2_PUBLIC_BASE in .env (e.g. https://pub-xxxx.r2.dev) to print public URLs"; fi ;;
  *)
    grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
