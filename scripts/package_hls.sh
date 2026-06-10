#!/usr/bin/env bash
# Offline HLS packaging: segment a source video into AES-128-encrypted .ts chunks
# + .m3u8, ready to upload to Cloudflare R2. The KEY stays here / goes to the DB;
# only the ENCRYPTED output goes to R2 (see ARCHITECTURE.md §2.2 / §4.2).
#
# Usage: scripts/package_hls.sh input.mp4 ./out <key_id> <key_url>
#   key_url = the Go API endpoint the player calls, e.g.
#             https://api.onrol.in/api/v1/hls/key/<video_id>
set -euo pipefail

IN="${1:?input video required}"
OUT="${2:?output dir required}"
KEY_ID="${3:?key id required}"
KEY_URL="${4:?key delivery URL required}"

mkdir -p "$OUT"

# 1. Generate a 16-byte AES-128 key (store these bytes in videos.encryption_key).
openssl rand 16 > "$OUT/$KEY_ID.key"
echo "[hls] key bytes (hex) — load into DB videos.encryption_key:"
xxd -p "$OUT/$KEY_ID.key"

# 2. ffmpeg key info file: <key URL the player hits> <local key file> [IV]
IV="$(openssl rand -hex 16)"
cat > "$OUT/$KEY_ID.keyinfo" <<EOF
$KEY_URL
$OUT/$KEY_ID.key
$IV
EOF

# 3. Segment + encrypt.
ffmpeg -i "$IN" \
  -c:v h264 -c:a aac \
  -hls_time 6 -hls_playlist_type vod \
  -hls_key_info_file "$OUT/$KEY_ID.keyinfo" \
  -hls_segment_filename "$OUT/seg_%05d.ts" \
  "$OUT/index.m3u8"

echo "[hls] done. Upload these to R2 (NOT the .key/.keyinfo files):"
echo "      $OUT/index.m3u8 and $OUT/seg_*.ts"
echo "[hls] keep $OUT/$KEY_ID.key secret — its bytes belong in the DB only."
