package handlers

import (
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
	rows, err := h.Pool.Query(c.Context(), `
		WITH d AS (
		  SELECT generate_series(
		           current_date - ($1::int - 1),
		           current_date,
		           interval '1 day')::date AS day
		),
		ev AS (
		  SELECT lp.user_id, lp.completed_at::date AS day, 'lesson' AS kind
		    FROM lesson_progress lp
		  UNION ALL
		  SELECT s.user_id, s.submitted_at::date, 'submission'
		    FROM submissions s
		  UNION ALL
		  SELECT m.user_id, m.created_at::date, 'question'
		    FROM module_comments m WHERE m.user_id IS NOT NULL
		)
		SELECT d.day::text,
		       count(*) FILTER (WHERE ev.kind = 'lesson')     AS lessons,
		       count(*) FILTER (WHERE ev.kind = 'submission') AS submissions,
		       count(*) FILTER (WHERE ev.kind = 'question')   AS questions,
		       count(DISTINCT ev.user_id)                     AS active
		FROM d LEFT JOIN ev ON ev.day = d.day
		GROUP BY d.day
		ORDER BY d.day`, days)
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
