#!/usr/bin/env bash
# End-to-end LMS smoke test: RBAC + course lifecycle + student consumption.
#   BASE=http://127.0.0.1:8080 ADMIN_KEY=dev-admin-key-123 scripts/lms_smoke.sh
set -euo pipefail
BASE="${BASE:-http://127.0.0.1:8080}"; ADMIN_KEY="${ADMIN_KEY:-dev-admin-key-123}"
jq() { python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get(sys.argv[1],"") if isinstance(d,dict) else "")' "$1"; }
pass(){ printf '  \033[32m✓\033[0m %s\n' "$1"; }
R=$RANDOM

login() { # email pass device -> token
  curl -s -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' -H "X-Device-UUID: $3" \
    -d "{\"email\":\"$1\",\"password\":\"$2\",\"platform\":\"web\"}" | jq access_token; }

echo "[1] bootstrap a MANAGER via admin key"
MGR="mgr$R@onrol.test"
curl -s -X POST "$BASE/api/v1/admin/users" -H "X-Admin-Key: $ADMIN_KEY" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$MGR\",\"full_name\":\"Dept Manager\",\"password\":\"Manager@123\",\"role\":\"manager\"}" >/dev/null
MTOK=$(login "$MGR" "Manager@123" "mgr-dev"); [ -n "$MTOK" ] && pass "manager created + logged in"

mauth=(-H "Authorization: Bearer $MTOK" -H "X-Device-UUID: mgr-dev")

echo "[2] manager creates a GROUP (auto-scoped to them)"
GID=$(curl -s -X POST "$BASE/api/v1/manage/groups" "${mauth[@]}" -H 'Content-Type: application/json' \
  -d '{"name":"Physics Dept","type":"department"}' | jq id); [ -n "$GID" ] && pass "group $GID"

echo "[3] manager creates a STUDENT in that group"
STU="stu$R@onrol.test"
curl -s -X POST "$BASE/api/v1/manage/users" "${mauth[@]}" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$STU\",\"full_name\":\"Test Student\",\"password\":\"Student@123\",\"role\":\"student\",\"group_id\":\"$GID\"}" >/dev/null
pass "student created in group"

echo "[4] manager creates + publishes a COURSE (group-scoped)"
CID=$(curl -s -X POST "$BASE/api/v1/manage/courses" "${mauth[@]}" -H 'Content-Type: application/json' \
  -d "{\"title\":\"Mechanics 101\",\"group_id\":\"$GID\",\"enroll_type\":\"manual\"}" | jq id)
curl -s -X PATCH "$BASE/api/v1/manage/courses/$CID" "${mauth[@]}" -H 'Content-Type: application/json' -d '{"status":"published"}' >/dev/null
pass "course $CID published"

echo "[5] add module + lesson"
MODID=$(curl -s -X POST "$BASE/api/v1/manage/courses/$CID/modules" "${mauth[@]}" -H 'Content-Type: application/json' -d '{"title":"Kinematics"}' | jq id)
LID=$(curl -s -X POST "$BASE/api/v1/manage/modules/$MODID/lessons" "${mauth[@]}" -H 'Content-Type: application/json' -d '{"title":"Intro","type":"text","body":"hello"}' | jq id)
pass "module+lesson added (lesson $LID)"

echo "[6] add assessment + MCQ question (published)"
AID=$(curl -s -X POST "$BASE/api/v1/manage/courses/$CID/assessments" "${mauth[@]}" -H 'Content-Type: application/json' -d '{"title":"Quiz 1","type":"quiz","is_published":true}' | jq id)
QID=$(curl -s -X POST "$BASE/api/v1/manage/assessments/$AID/questions" "${mauth[@]}" -H 'Content-Type: application/json' \
  -d '{"prompt":"2+2?","type":"mcq","options":["3","4","5"],"correct":"4","points":10}' | jq id)
pass "assessment $AID + question $QID"

echo "[7] manager enrolls the student in the course"
curl -s -X POST "$BASE/api/v1/manage/courses/$CID/enroll" "${mauth[@]}" -H 'Content-Type: application/json' -d "{\"user_id\":\"$(curl -s "$BASE/api/v1/manage/users" "${mauth[@]}" | python3 -c "import sys,json;us=json.load(sys.stdin)['users'];print(next(u['id'] for u in us if u['email']=='$STU'))")\"}" >/dev/null
pass "student enrolled"

echo "[8] STUDENT logs in, sees course, completes lesson"
STOK=$(login "$STU" "Student@123" "stu-dev")
sauth=(-H "Authorization: Bearer $STOK" -H "X-Device-UUID: stu-dev")
MC=$(curl -s "$BASE/api/v1/me/courses" "${sauth[@]}" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["my_courses"]))')
[ "$MC" -ge 1 ] && pass "student sees $MC enrolled course(s)"
curl -s -X POST "$BASE/api/v1/me/lessons/$LID/complete" "${sauth[@]}" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  course_completed="+str(d.get("course_completed")))'

echo "[9] STUDENT takes + submits the quiz (auto-grade MCQ)"
curl -s "$BASE/api/v1/me/assessments/$AID" "${sauth[@]}" >/dev/null
SUB=$(curl -s -X POST "$BASE/api/v1/me/assessments/$AID/submit" "${sauth[@]}" -H 'Content-Type: application/json' -d "{\"answers\":{\"$QID\":\"4\"}}")
echo "$SUB" | python3 -c 'import sys,json;d=json.load(sys.stdin);print("  auto_score="+str(d.get("auto_score"))+" status="+str(d.get("status")))'
[ "$(echo "$SUB" | jq auto_score)" = "10" ] && pass "MCQ auto-graded correctly (10 pts)"

echo "[10] RBAC: student is BLOCKED from a manager route (expect 403)"
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/v1/manage/groups" "${sauth[@]}" -H 'Content-Type: application/json' -d '{"name":"hack"}')
[ "$CODE" = "403" ] && pass "student blocked from /manage (403)"

echo; echo "LMS SMOKE PASSED ✓"