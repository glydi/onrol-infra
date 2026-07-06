// Package autoprovision turns converted leads into LMS student accounts
// automatically. A converted lead with a course_id (the key) becomes a student,
// keyed to that course (course_label), and enrolled into it — on a schedule,
// idempotently. Each account gets the standard default password (onrol@ai),
// recorded in provisioning_log; students sign in with their email, phone, or the
// auto-assigned 6-char login_id.
package autoprovision

import (
	"context"
	"log"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// Start launches the background loop: an initial run shortly after boot, then
// every interval. Safe to run repeatedly — every statement is idempotent.
func Start(pool *pgxpool.Pool, interval time.Duration) {
	go func() {
		time.Sleep(8 * time.Second) // let the server settle first
		runOnce(pool)
		t := time.NewTicker(interval)
		defer t.Stop()
		for range t.C {
			runOnce(pool)
		}
	}()
}

func runOnce(pool *pgxpool.Pool) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	for i, stmt := range steps {
		if _, err := pool.Exec(ctx, stmt); err != nil {
			log.Printf("autoprovision: step %d failed: %v", i+1, err)
			return // try again next tick
		}
	}
}

// All steps key strictly on the lead's course_id. A lead with no course_id is
// left untouched (never auto-provisioned, never deleted).
var steps = []string{
	// 1. Ensure a course exists for each course_id (titled from course_title).
	`INSERT INTO courses (title, label, status, enroll_type)
	 SELECT DISTINCT ON (lower(trim(b.course_id)))
	        COALESCE(NULLIF(trim(b.course_title),''), trim(b.course_id)),
	        lower(trim(b.course_id)), 'draft', 'manual'
	 FROM converted_leads_backup b
	 WHERE NULLIF(trim(b.course_id),'') IS NOT NULL
	   AND NOT EXISTS (SELECT 1 FROM courses c WHERE lower(c.label)=lower(trim(b.course_id)))
	 ORDER BY lower(trim(b.course_id)), b.backed_up_at DESC`,

	// 2. Create accounts for course_id leads that don't have one, log the temp
	//    password. Deduped per email (a person may convert under two courses).
	`WITH cand AS MATERIALIZED (
	   SELECT DISTINCT ON (email) lead_id, full_name, phone, username, email, course_label, temp_password
	   FROM (
	     SELECT
	       b.lead_id,
	       COALESCE(NULLIF(trim(b.name),''),'Student') AS full_name,
	       NULLIF(trim(b.phone),'') AS phone,
	       NULLIF(regexp_replace(COALESCE(b.phone,''),'\D','','g'),'') AS username,
	       lower(trim(b.course_id)) AS course_label,
	       CASE
	         WHEN lower(trim(COALESCE(b.email,'')))<>'' THEN lower(trim(b.email))
	         WHEN regexp_replace(COALESCE(b.phone,''),'\D','','g')<>'' THEN regexp_replace(COALESCE(b.phone,''),'\D','','g')||'@students.onrol.local'
	         ELSE 'lead-'||b.lead_id||'@students.onrol.local'
	       END AS email,
	       'onrol@ai' AS temp_password
	     FROM converted_leads_backup b
	     WHERE NULLIF(trim(b.course_id),'') IS NOT NULL
	   ) r
	   WHERE NOT EXISTS (
	     SELECT 1 FROM users u WHERE u.email=r.email OR (r.username IS NOT NULL AND lower(u.username)=r.username)
	   )
	   ORDER BY email
	 ),
	 ins AS (
	   INSERT INTO users (email, username, phone, full_name, password_hash, role, course_label)
	   SELECT email, username, phone, full_name, crypt(temp_password, gen_salt('bf',10)), 'student', course_label
	   FROM cand
	   RETURNING id, email
	 )
	 INSERT INTO provisioning_log (user_id, full_name, username, email, temp_password, course_label)
	 SELECT i.id, c.full_name, c.username, c.email, c.temp_password, c.course_label
	 FROM ins i JOIN cand c ON c.email = i.email`,

	// 3. Re-key existing students' course_label to their lead's course_id.
	`UPDATE users u SET course_label = lower(trim(b.course_id)), updated_at=now()
	 FROM converted_leads_backup b
	 WHERE u.role='student' AND NULLIF(trim(b.course_id),'') IS NOT NULL
	   AND ( (u.email<>'' AND lower(u.email)=lower(trim(b.email)))
	      OR (u.username = regexp_replace(COALESCE(b.phone,''),'\D','','g')) )
	   AND u.course_label IS DISTINCT FROM lower(trim(b.course_id))`,

	// 4. Enrol students into the LMS course matching their lead's course_id.
	`INSERT INTO course_enrollments (course_id, user_id, status)
	 SELECT DISTINCT c.id, u.id, 'active'
	 FROM converted_leads_backup b
	 JOIN courses c ON lower(c.label) = lower(trim(b.course_id))
	 JOIN users u ON u.role='student' AND ( (u.email<>'' AND lower(u.email)=lower(trim(b.email)))
	      OR (u.username = regexp_replace(COALESCE(b.phone,''),'\D','','g')) )
	 WHERE NULLIF(trim(b.course_id),'') IS NOT NULL
	 ON CONFLICT (course_id,user_id) DO NOTHING`,

	// 5. Keep each course's display title synced with the lead's course_title.
	`UPDATE courses c SET title = sub.t
	 FROM (
	   SELECT DISTINCT ON (lower(trim(course_id))) lower(trim(course_id)) AS cid, trim(course_title) AS t
	   FROM converted_leads_backup
	   WHERE NULLIF(trim(course_id),'') IS NOT NULL AND NULLIF(trim(course_title),'') IS NOT NULL
	   ORDER BY lower(trim(course_id))
	 ) sub
	 WHERE lower(c.label)=sub.cid AND c.title IS DISTINCT FROM sub.t`,

	// 6. Time-box access: a converted student's account is valid for numberofdays
	//    from conversion. Keep users.access_expires_at in sync (login and the auth
	//    middleware deny access once it passes). Anchored to a stable date
	//    (converted_at, else the account's created_at) so the value never drifts.
	`UPDATE users u
	 SET access_expires_at = COALESCE(b.converted_at, u.created_at) + (b.numberofdays || ' days')::interval,
	     updated_at = now()
	 FROM converted_leads_backup b
	 WHERE u.role='student' AND NULLIF(trim(b.course_id),'') IS NOT NULL
	   AND b.numberofdays IS NOT NULL AND b.numberofdays > 0
	   AND ( (u.email<>'' AND lower(u.email)=lower(trim(b.email)))
	      OR (u.username = regexp_replace(COALESCE(b.phone,''),'\D','','g')) )
	   AND u.access_expires_at IS DISTINCT FROM (COALESCE(b.converted_at, u.created_at) + (b.numberofdays || ' days')::interval)`,

	// 7. Auto-push: a course can nominate a batch (courses.batch_target) that new
	//    students are dropped into as they arrive. Push any unbatched student in
	//    such a course into that batch, so new entries land there automatically.
	`UPDATE users u
	 SET batch = NULLIF(trim(c.batch_target),''), updated_at = now()
	 FROM courses c
	 WHERE u.role='student' AND u.batch IS NULL
	   AND lower(u.course_label) = lower(c.label)
	   AND NULLIF(trim(c.batch_target),'') IS NOT NULL`,
}
