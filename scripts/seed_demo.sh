#!/usr/bin/env bash
# Seed demo content so demo@onrol.in has a populated Apple-style dashboard.
#   BASE=https://187-127-178-100.sslip.io ADMIN_KEY=... scripts/seed_demo.sh
set -euo pipefail
BASE="${BASE:?}"; ADMIN_KEY="${ADMIN_KEY:?}"
j(){ python3 -c 'import sys,json;d=json.load(sys.stdin);print(d.get(sys.argv[1],"") if isinstance(d,dict) else "")' "$1"; }
login(){ curl -s -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' -H "X-Device-UUID: $3" -d "{\"email\":\"$1\",\"password\":\"$2\",\"platform\":\"web\"}" | j access_token; }

# 1) Seed instructor.
INS="seed.instructor@onrol.in"
curl -s -X POST "$BASE/api/v1/admin/users" -H "X-Admin-Key: $ADMIN_KEY" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$INS\",\"full_name\":\"Anita Verma\",\"password\":\"Seed@12345\",\"role\":\"instructor\"}" >/dev/null 2>&1 || true
ITOK=$(login "$INS" "Seed@12345" "seed-inst")
ia=(-H "Authorization: Bearer $ITOK" -H "X-Device-UUID: seed-inst")

mk_course(){ # title enrolltype  -> id (creates module + 3 lessons, publishes)
  local cid; cid=$(curl -s -X POST "$BASE/api/v1/manage/courses" "${ia[@]}" -H 'Content-Type: application/json' \
    -d "{\"title\":\"$1\",\"description\":\"$3\",\"enroll_type\":\"$2\"}" | j id)
  local mod; mod=$(curl -s -X POST "$BASE/api/v1/manage/courses/$cid/modules" "${ia[@]}" -H 'Content-Type: application/json' -d '{"title":"Getting Started"}' | j id)
  for n in 1 2 3; do
    curl -s -X POST "$BASE/api/v1/manage/modules/$mod/lessons" "${ia[@]}" -H 'Content-Type: application/json' \
      -d "{\"title\":\"Lesson $n\",\"type\":\"text\",\"body\":\"...\"}" >/dev/null
  done
  curl -s -X PATCH "$BASE/api/v1/manage/courses/$cid" "${ia[@]}" -H 'Content-Type: application/json' -d '{"status":"published"}' >/dev/null
  echo "$cid"
}

C1=$(mk_course "Physics: Mechanics" self "Newtonian motion, forces and energy.")
C2=$(mk_course "Calculus I" self "Limits, derivatives and integrals.")
C3=$(mk_course "Organic Chemistry" manual "Reactions, mechanisms and synthesis.")
C4=$(mk_course "Indian History" manual "Ancient to modern India.")
echo "courses: $C1 $C2 $C3 $C4"

# 2) demo self-enrolls in the two self-enroll courses + completes some lessons.
DTOK=$(login "demo@onrol.in" "Onrol@12345" "seed-demo")
da=(-H "Authorization: Bearer $DTOK" -H "X-Device-UUID: seed-demo")
for c in "$C1" "$C2"; do curl -s -X POST "$BASE/api/v1/me/courses/$c/enroll" "${da[@]}" >/dev/null; done

# Complete 2 of 3 lessons in C1 to show ~66% progress.
LESSONS=$(curl -s "$BASE/api/v1/me/courses/$C1/content" "${da[@]}" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(" ".join(l["id"] for m in d["modules"] for l in m["lessons"]))')
i=0; for lid in $LESSONS; do [ $i -lt 2 ] && curl -s -X POST "$BASE/api/v1/me/lessons/$lid/complete" "${da[@]}" >/dev/null; i=$((i+1)); done
echo "demo enrolled in 2 courses, partial progress on C1"

# 3) Free demo's device slots so the user logs in fresh in their browser.
for id in $(curl -s "$BASE/api/v1/devices" "${da[@]}" | python3 -c 'import sys,json;[print(d["id"]) for d in json.load(sys.stdin)["devices"]]'); do
  curl -s -X DELETE "$BASE/api/v1/devices/$id" "${da[@]}" >/dev/null || true
done
echo "demo device slots cleared ✓"
echo "SEED DONE"