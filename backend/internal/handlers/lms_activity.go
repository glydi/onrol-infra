package handlers

import (
	"strings"

	"strconv"

	"github.com/gofiber/fiber/v2"
)

// StudentActivity: what students actually did, per day, for the Home overview.
//
// Three event streams share one shape (who, when), so they're unioned into a
// single series and counted with FILTER rather than run as three subqueries per
// day. generate_series supplies the calendar so quiet days come back as zeros
// instead of gaps — a chart needs a continuous axis.
func (h *Handlers) StudentActivity(c *fiber.Ctx) error {
	days := 14
	if v, err := strconv.Atoi(c.Query("days")); err == nil && v >= 1 && v <= 90 {
		days = v
	}
	// Optional filters. Empty string = no filter; the SQL short-circuits so one
	// query shape serves every combination.
	batch := strings.TrimSpace(c.Query("batch"))
	course := strings.TrimSpace(c.Query("course"))

	// The batch/course filter lives INSIDE the events CTE, not in a WHERE after
	// the LEFT JOIN — filtering after the join would discard the zero rows the
	// calendar exists to produce, and the chart would show gaps as missing days.
	rows, err := h.Pool.Query(c.Context(), `
		WITH d AS (
		  SELECT generate_series(
		           current_date - ($1::int - 1),
		           current_date,
		           interval '1 day')::date AS day
		),
		raw AS (
		  SELECT lp.user_id, lp.completed_at::date AS day, 'lesson' AS kind
		    FROM lesson_progress lp
		  UNION ALL
		  SELECT s.user_id, s.submitted_at::date, 'submission'
		    FROM submissions s
		  UNION ALL
		  SELECT m.user_id, m.created_at::date, 'question'
		    FROM module_comments m WHERE m.user_id IS NOT NULL
		),
		ev AS (
		  SELECT raw.user_id, raw.day, raw.kind
		    FROM raw JOIN users u ON u.id = raw.user_id
		   WHERE ($2::text = '' OR u.batch = $2::text)
		     AND ($3::text = '' OR lower(u.course_label) = lower($3::text))
		)
		SELECT d.day::text,
		       count(*) FILTER (WHERE ev.kind = 'lesson')     AS lessons,
		       count(*) FILTER (WHERE ev.kind = 'submission') AS submissions,
		       count(*) FILTER (WHERE ev.kind = 'question')   AS questions,
		       count(DISTINCT ev.user_id)                     AS active
		FROM d LEFT JOIN ev ON ev.day = d.day
		GROUP BY d.day
		ORDER BY d.day`, days, batch, course)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "activity failed")
	}
	defer rows.Close()

	out := []fiber.Map{}
	var totLessons, totSubs, totQs int
	for rows.Next() {
		var day string
		var lessons, subs, questions, active int
		if err := rows.Scan(&day, &lessons, &subs, &questions, &active); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		totLessons += lessons
		totSubs += subs
		totQs += questions
		out = append(out, fiber.Map{
			"date": day, "lessons": lessons, "submissions": subs,
			"questions": questions, "active": active,
		})
	}
	return c.JSON(fiber.Map{
		"days":              out,
		"total_lessons":     totLessons,
		"total_submissions": totSubs,
		"total_questions":   totQs,
	})
}
