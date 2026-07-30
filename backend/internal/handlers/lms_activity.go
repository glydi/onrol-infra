package handlers

import (
	"strings"

	"strconv"

	"github.com/gofiber/fiber/v2"
)

// StudentActivity: what students actually did, per bucket, for the Home overview.
//
// Five event streams share one shape (who, when, optionally a score), so they're
// unioned into a single series and counted with FILTER rather than run as five
// subqueries per bucket. generate_series supplies the calendar so quiet periods
// come back as zeros instead of gaps — a chart needs a continuous axis.
//
// Usage (lessons, submissions, questions) and performance (attendance, scores)
// come back together in one response: the client picks which series to draw, so
// switching metric in the UI costs no request and every metric shares one axis.
func (h *Handlers) StudentActivity(c *fiber.Ctx) error {
	days := 14
	if v, err := strconv.Atoi(c.Query("days")); err == nil && v >= 1 && v <= 365 {
		days = v
	}
	// Optional filters. Empty string = no filter; the SQL short-circuits so one
	// query shape serves every combination — including "all courses/batches".
	batch := strings.TrimSpace(c.Query("batch"))
	course := strings.TrimSpace(c.Query("course"))

	// Bucket width. Whitelisted rather than interpolated — it reaches SQL as a
	// bound parameter to date_trunc, so there is nothing to inject.
	bucket := "day"
	if strings.EqualFold(c.Query("granularity"), "week") {
		bucket = "week"
	}

	// The batch/course filter lives INSIDE the events CTE, not in a WHERE after
	// the LEFT JOIN — filtering after the join would discard the zero rows the
	// calendar exists to produce, and the chart would show gaps as missing days.
	rows, err := h.Pool.Query(c.Context(), `
		WITH d AS (
		  SELECT DISTINCT date_trunc($4::text, gs)::date AS bucket
		    FROM generate_series(
		           current_date - ($1::int - 1),
		           current_date,
		           interval '1 day') gs
		),
		raw AS (
		  SELECT lp.user_id, lp.completed_at::date AS day, 'lesson' AS kind,
		         NULL::numeric AS score
		    FROM lesson_progress lp
		  UNION ALL
		  SELECT s.user_id, s.submitted_at::date, 'submission', s.score
		    FROM submissions s
		  UNION ALL
		  SELECT m.user_id, m.created_at::date, 'question', NULL::numeric
		    FROM module_comments m WHERE m.user_id IS NOT NULL
		  UNION ALL
		  SELECT sa.user_id, sa.marked_at::date, 'present', NULL::numeric
		    FROM session_attendance sa WHERE sa.status = 'present'
		  UNION ALL
		  SELECT sa.user_id, sa.marked_at::date, 'absent', NULL::numeric
		    FROM session_attendance sa WHERE sa.status = 'absent'
		),
		ev AS (
		  SELECT raw.user_id, date_trunc($4::text, raw.day)::date AS bucket,
		         raw.kind, raw.score
		    FROM raw JOIN users u ON u.id = raw.user_id
		   WHERE ($2::text = '' OR u.batch = $2::text)
		     AND ($3::text = '' OR lower(u.course_label) = lower($3::text))
		)
		SELECT d.bucket::text,
		       count(*) FILTER (WHERE ev.kind = 'lesson')     AS lessons,
		       count(*) FILTER (WHERE ev.kind = 'submission') AS submissions,
		       count(*) FILTER (WHERE ev.kind = 'question')   AS questions,
		       count(*) FILTER (WHERE ev.kind = 'present')    AS present,
		       count(*) FILTER (WHERE ev.kind = 'absent')     AS absent,
		       count(DISTINCT ev.user_id)                     AS active,
		       -- Ungraded submissions carry a NULL score; avg ignores them, so an
		       -- all-ungraded bucket reads 0 instead of dragging the line down.
		       coalesce(round(avg(ev.score) FILTER (WHERE ev.kind = 'submission'), 1), 0) AS avg_score
		FROM d LEFT JOIN ev ON ev.bucket = d.bucket
		GROUP BY d.bucket
		ORDER BY d.bucket`, days, batch, course, bucket)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "activity failed")
	}
	defer rows.Close()

	out := []fiber.Map{}
	var totLessons, totSubs, totQs, totPresent, totAbsent int
	// Score is averaged over buckets that actually had a graded submission —
	// counting empty buckets would report a falsely low cohort average.
	var scoreSum float64
	var scoreBuckets int
	for rows.Next() {
		var day string
		var lessons, subs, questions, present, absent, active int
		var avgScore float64
		if err := rows.Scan(&day, &lessons, &subs, &questions, &present, &absent, &active, &avgScore); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		totLessons += lessons
		totSubs += subs
		totQs += questions
		totPresent += present
		totAbsent += absent
		if avgScore > 0 {
			scoreSum += avgScore
			scoreBuckets++
		}
		out = append(out, fiber.Map{
			"date": day, "lessons": lessons, "submissions": subs,
			"questions": questions, "present": present, "absent": absent,
			"active": active, "avg_score": avgScore,
		})
	}

	// Distinct learners over the WHOLE window, plus the cohort they're drawn
	// from. Can't be derived from the per-bucket rows above — summing daily
	// actives counts the same student once per day they showed up. Paired with
	// [enrolled] so the caller can show participation as a share, not a count.
	var activeWindow, enrolled int
	_ = h.Pool.QueryRow(c.Context(), `
		WITH raw AS (
		  SELECT lp.user_id, lp.completed_at::date AS day FROM lesson_progress lp
		  UNION ALL SELECT s.user_id, s.submitted_at::date FROM submissions s
		  UNION ALL SELECT m.user_id, m.created_at::date FROM module_comments m
		   WHERE m.user_id IS NOT NULL
		  UNION ALL SELECT sa.user_id, sa.marked_at::date FROM session_attendance sa
		)
		SELECT
		  (SELECT count(DISTINCT raw.user_id)
		     FROM raw JOIN users u ON u.id = raw.user_id
		    WHERE raw.day > current_date - $1::int
		      AND ($2::text = '' OR u.batch = $2::text)
		      AND ($3::text = '' OR lower(u.course_label) = lower($3::text))),
		  (SELECT count(*) FROM users u
		    WHERE u.role = 'student' AND u.is_active
		      AND ($2::text = '' OR u.batch = $2::text)
		      AND ($3::text = '' OR lower(u.course_label) = lower($3::text)))`,
		days, batch, course).Scan(&activeWindow, &enrolled)

	avgScore := 0.0
	if scoreBuckets > 0 {
		avgScore = scoreSum / float64(scoreBuckets)
	}
	// Attendance rate over the window, not per bucket — a single number the
	// header can show next to the chart.
	attendanceRate := 0.0
	if totPresent+totAbsent > 0 {
		attendanceRate = float64(totPresent) / float64(totPresent+totAbsent) * 100
	}
	return c.JSON(fiber.Map{
		"days":              out,
		"granularity":       bucket,
		"active_learners":   activeWindow,
		"enrolled":          enrolled,
		"total_lessons":     totLessons,
		"total_submissions": totSubs,
		"total_questions":   totQs,
		"total_present":     totPresent,
		"total_absent":      totAbsent,
		"attendance_rate":   attendanceRate,
		"avg_score":         avgScore,
	})
}
