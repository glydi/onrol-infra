package handlers

import (
	"math"
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
		  -- Attendance comes from live_attendance (a row per learner who actually
		  -- joined a class), NOT session_attendance — the latter is a manual
		  -- present/absent marking table that nobody has ever filled in.
		  SELECT la.user_id, la.first_seen::date, 'attended', NULL::numeric
		    FROM live_attendance la
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
		       count(*) FILTER (WHERE ev.kind = 'attended')   AS attended,
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
	var totLessons, totSubs, totQs, totAttended int
	// Score is averaged over buckets that actually had a graded submission —
	// counting empty buckets would report a falsely low cohort average.
	var scoreSum float64
	var scoreBuckets int
	for rows.Next() {
		var day string
		var lessons, subs, questions, attended, active int
		var avgScore float64
		if err := rows.Scan(&day, &lessons, &subs, &questions, &attended, &active, &avgScore); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		totLessons += lessons
		totSubs += subs
		totQs += questions
		totAttended += attended
		if avgScore > 0 {
			scoreSum += avgScore
			scoreBuckets++
		}
		out = append(out, fiber.Map{
			"date": day, "lessons": lessons, "submissions": subs,
			"questions": questions, "attended": attended,
			"active": active, "avg_score": avgScore,
		})
	}

	// Distinct learners over the WHOLE window, plus the cohort they're drawn
	// from. Can't be derived from the per-bucket rows above — summing daily
	// actives counts the same student once per day they showed up. Paired with
	// [enrolled] so the caller can show participation as a share, not a count.
	//
	// Learning hours ride along in the same round trip. Two sources, summed:
	// live_attendance.watched_seconds is genuine cumulative time in a live class,
	// while lesson_playback.position_seconds is a resume pointer — the furthest
	// point reached in a recording, one row per learner per lesson. The latter is
	// a proxy, not measured time: a rewatch adds nothing and a skip-ahead
	// overstates. It's the best signal available, so hours are an estimate.
	var activeWindow, enrolled, attendedUsers int
	var totalSecs, windowSecs float64
	_ = h.Pool.QueryRow(c.Context(), `
		WITH raw AS (
		  SELECT lp.user_id, lp.completed_at::date AS day FROM lesson_progress lp
		  UNION ALL SELECT s.user_id, s.submitted_at::date FROM submissions s
		  UNION ALL SELECT m.user_id, m.created_at::date FROM module_comments m
		   WHERE m.user_id IS NOT NULL
		  UNION ALL SELECT la.user_id, la.first_seen::date FROM live_attendance la
		),
		f AS (
		  SELECT id FROM users u
		   WHERE ($2::text = '' OR u.batch = $2::text)
		     AND ($3::text = '' OR lower(u.course_label) = lower($3::text))
		)
		SELECT
		  (SELECT count(DISTINCT raw.user_id)
		     FROM raw JOIN f ON f.id = raw.user_id
		    WHERE raw.day > current_date - $1::int),
		  (SELECT count(*) FROM users u JOIN f ON f.id = u.id
		    WHERE u.role = 'student' AND u.is_active),
		  (SELECT count(DISTINCT la.user_id)
		     FROM live_attendance la JOIN f ON f.id = la.user_id
		    WHERE la.first_seen::date > current_date - $1::int),
		  (SELECT coalesce(sum(la.watched_seconds), 0)
		     FROM live_attendance la JOIN f ON f.id = la.user_id)
		  + (SELECT coalesce(sum(pb.position_seconds), 0)
		       FROM lesson_playback pb JOIN f ON f.id = pb.user_id),
		  (SELECT coalesce(sum(la.watched_seconds), 0)
		     FROM live_attendance la JOIN f ON f.id = la.user_id
		    WHERE la.last_seen::date > current_date - $1::int)
		  + (SELECT coalesce(sum(pb.position_seconds), 0)
		       FROM lesson_playback pb JOIN f ON f.id = pb.user_id
		      WHERE pb.updated_at::date > current_date - $1::int)`,
		days, batch, course).
		Scan(&activeWindow, &enrolled, &attendedUsers, &totalSecs, &windowSecs)

	avgScore := 0.0
	if scoreBuckets > 0 {
		avgScore = scoreSum / float64(scoreBuckets)
	}
	// Share of the cohort that turned up to at least one live class in the
	// window. There's no absent record to divide by — a learner who never joined
	// simply has no row — so the roster is the denominator.
	attendanceRate := 0.0
	if enrolled > 0 {
		attendanceRate = float64(attendedUsers) / float64(enrolled) * 100
	}
	return c.JSON(fiber.Map{
		"days":              out,
		"granularity":       bucket,
		"active_learners":   activeWindow,
		"enrolled":          enrolled,
		"total_lessons":     totLessons,
		"total_submissions": totSubs,
		"total_questions":   totQs,
		"total_attended":    totAttended,
		"attended_learners": attendedUsers,
		"attendance_rate":   attendanceRate,
		// Rounded to one decimal — the UI shows "186.0 h", never seconds.
		"total_hours":  math.Round(totalSecs/360) / 10,
		"window_hours": math.Round(windowSecs/360) / 10,
		"avg_score":         avgScore,
	})
}
