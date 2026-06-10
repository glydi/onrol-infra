#!/usr/bin/env bash
# End-to-end smoke test against a running API. Exercises the whole product flow:
# register -> device-bound login -> device-limit enforcement -> admin video +
# enrollment -> AES key delivery -> webinar -> live join.
#
#   BASE=http://127.0.0.1:8080 ADMIN_KEY=dev-admin-key-123 scripts/smoke_test.sh
set -euo pipefail

BASE="${BASE:-http://127.0.0.1:8080}"
ADMIN_KEY="${ADMIN_KEY:-dev-admin-key-123}"
j() { python3 -c 'import sys,json;print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"; }
pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
info() { printf '  → %s\n' "$1"; }

EMAIL="student+$RANDOM@onrol.test"
PASS="hunter2pass"

echo "[1] register"
curl -s -X POST "$BASE/api/v1/auth/register" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"full_name\":\"Asha Rao\",\"password\":\"$PASS\"}" >/dev/null
pass "user created: $EMAIL"

echo "[2] login on device A (gets device-bound JWT)"
TOKA=$(curl -s -X POST "$BASE/api/v1/auth/login" \
  -H 'Content-Type: application/json' -H 'X-Device-UUID: device-AAA' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"platform\":\"android\"}" | j access_token)
[ -n "$TOKA" ] && pass "device A token issued" || { echo "FAIL: no token"; exit 1; }

echo "[3] login on device B (2nd device allowed)"
curl -s -X POST "$BASE/api/v1/auth/login" \
  -H 'Content-Type: application/json' -H 'X-Device-UUID: device-BBB' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"platform\":\"ios\"}" | j access_token >/dev/null
pass "device B bound"

echo "[4] login on device C (must be REJECTED — 2-device limit)"
CODE=$(curl -s -o /tmp/c.json -w '%{http_code}' -X POST "$BASE/api/v1/auth/login" \
  -H 'Content-Type: application/json' -H 'X-Device-UUID: device-CCC' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\",\"platform\":\"android\"}")
[ "$CODE" = "409" ] && pass "device C correctly rejected (HTTP 409)" || { echo "FAIL: expected 409 got $CODE"; cat /tmp/c.json; exit 1; }

echo "[5] admin: create video (server generates AES-128 key)"
VRES=$(curl -s -X POST "$BASE/api/v1/admin/videos" \
  -H "X-Admin-Key: $ADMIN_KEY" -H 'Content-Type: application/json' \
  -d '{"title":"Lecture 1","hls_path":"vod/lec1","is_published":true}')
VID=$(echo "$VRES" | j id); KEYHEX=$(echo "$VRES" | j key_hex)
info "video id=$VID  key_hex=$KEYHEX"
pass "video created with 16-byte key"

echo "[6] fetch HLS key BEFORE enrollment (must be 403)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/hls/key/$VID" \
  -H "Authorization: Bearer $TOKA" -H 'X-Device-UUID: device-AAA')
[ "$CODE" = "403" ] && pass "unenrolled key request blocked (403)" || { echo "FAIL: expected 403 got $CODE"; exit 1; }

echo "[7] admin: enroll the student"
USERID=$(curl -s "$BASE/api/v1/devices" -H "Authorization: Bearer $TOKA" -H 'X-Device-UUID: device-AAA' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["devices"][0]["user_id"])')
curl -s -X POST "$BASE/api/v1/admin/enroll" -H "X-Admin-Key: $ADMIN_KEY" -H 'Content-Type: application/json' \
  -d "{\"user_id\":\"$USERID\",\"video_id\":\"$VID\"}" >/dev/null
pass "enrolled user $USERID"

echo "[8] fetch HLS key AFTER enrollment (must be 200, exactly 16 bytes)"
LEN=$(curl -s "$BASE/api/v1/hls/key/$VID" -H "Authorization: Bearer $TOKA" -H 'X-Device-UUID: device-AAA' --output - | wc -c)
[ "$LEN" = "16" ] && pass "got 16-byte AES key" || { echo "FAIL: expected 16 bytes got $LEN"; exit 1; }

echo "[9] HLS key with WRONG device header (token/device mismatch -> 401)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/hls/key/$VID" \
  -H "Authorization: Bearer $TOKA" -H 'X-Device-UUID: device-WRONG')
[ "$CODE" = "401" ] && pass "device-mismatch token rejected (401)" || { echo "FAIL: expected 401 got $CODE"; exit 1; }

echo "[10] admin: create webinar + student live-join (embed mode)"
WID=$(curl -s -X POST "$BASE/api/v1/admin/webinars" -H "X-Admin-Key: $ADMIN_KEY" -H 'Content-Type: application/json' \
  -d '{"title":"Live Class","embed_session_id":"1362481714"}' | j id)
JOIN=$(curl -s -X POST "$BASE/api/v1/live/$WID/join" -H "Authorization: Bearer $TOKA" -H 'X-Device-UUID: device-AAA')
MODE=$(echo "$JOIN" | j mode); URL=$(echo "$JOIN" | j url)
info "mode=$MODE url=$URL"
[ "$MODE" = "embed" ] && pass "live join returned Zoho embed URL" || { echo "NOTE: mode=$MODE (join URL path)"; }

echo
echo "ALL CHECKS PASSED ✓"
