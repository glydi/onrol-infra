package handlers

import (
	"time"

	"github.com/gofiber/fiber/v2"
)

// xpPerLesson — the same rule the dashboard uses (10 XP per completed lesson).
const xpPerLesson = 10

// MyLeaderboard ranks students by lessons completed (real data from
// lesson_progress). Each row carries the learner's name, avatar, lesson count,
// derived XP and the course they've progressed most in. The caller is always
// included (appended with their true rank if they fall outside the top slice)
// and flagged with is_me so the UI can highlight them.
func (h *Handlers) MyLeaderboard(c *fiber.Ctx) error {
	me := callerID(c)
	rows, err := h.Pool.Query(c.Context(), `
		WITH per_user AS (
		  SELECT u.id, u.full_name, COALESCE(u.username,'') AS username,
		         COALESCE(u.avatar,'') AS avatar,
		         COUNT(lp.lesson_id) AS lessons
		  FROM users u
		  LEFT JOIN lesson_progress lp ON lp.user_id = u.id
		  WHERE u.role = 'student'
		  GROUP BY u.id, u.full_name, u.username, u.avatar
		)
		SELECT pu.id, pu.full_name, pu.username, pu.avatar, pu.lessons,
		  COALESCE((
		    SELECT c.title FROM course_enrollments ce JOIN courses c ON c.id = ce.course_id
		    WHERE ce.user_id = pu.id
		    ORDER BY (
		      SELECT count(*) FROM lesson_progress lp2
		      JOIN lessons l ON l.id = lp2.lesson_id
		      JOIN modules m ON m.id = l.module_id
		      WHERE m.course_id = c.id AND lp2.user_id = pu.id
		    ) DESC, ce.enrolled_at DESC
		    LIMIT 1
		  ), '') AS top_course,
		  (SELECT count(*) FROM course_enrollments ce WHERE ce.user_id = pu.id) AS courses
		FROM per_user pu
		ORDER BY pu.lessons DESC, pu.full_name ASC
		LIMIT 25`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "leaderboard failed")
	}
	defer rows.Close()

	out := []fiber.Map{}
	myRank := 0
	rank := 0
	for rows.Next() {
		var id, name, username, avatar, topCourse string
		var lessons, courses int
		if err := rows.Scan(&id, &name, &username, &avatar, &lessons, &topCourse, &courses); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		rank++
		isMe := id == me
		if isMe {
			myRank = rank
		}
		out = append(out, leaderRow(rank, name, username, avatar, topCourse, lessons, courses, isMe))
	}

	// If the caller isn't in the top slice, append their own row with their true
	// rank so they can always see where they stand.
	if myRank == 0 {
		var name, username, avatar, topCourse string
		var lessons, courses, rnk int
		err := h.Pool.QueryRow(c.Context(), `
			SELECT u.full_name, COALESCE(u.username,''), COALESCE(u.avatar,''),
			  (SELECT count(*) FROM lesson_progress lp WHERE lp.user_id = u.id),
			  (SELECT count(*) FROM course_enrollments ce WHERE ce.user_id = u.id),
			  1 + (SELECT count(*) FROM (
			        SELECT u2.id, count(lp2.lesson_id) AS l FROM users u2
			        LEFT JOIN lesson_progress lp2 ON lp2.user_id = u2.id
			        WHERE u2.role = 'student' GROUP BY u2.id
			      ) t WHERE t.l > (SELECT count(*) FROM lesson_progress WHERE user_id = u.id)),
			  COALESCE((
			    SELECT c.title FROM course_enrollments ce JOIN courses c ON c.id = ce.course_id
			    WHERE ce.user_id = u.id ORDER BY ce.enrolled_at DESC LIMIT 1
			  ), '')
			FROM users u WHERE u.id = $1`, me).
			Scan(&name, &username, &avatar, &lessons, &courses, &rnk, &topCourse)
		if err == nil && name != "" {
			myRank = rnk
			out = append(out, leaderRow(rnk, name, username, avatar, topCourse, lessons, courses, true))
		}
	}

	return c.JSON(fiber.Map{"leaderboard": out, "my_rank": myRank})
}

func leaderRow(rank int, name, username, avatar, course string, lessons, courses int, isMe bool) fiber.Map {
	return fiber.Map{
		"rank": rank, "name": name, "username": username, "avatar": avatar,
		"course": course, "courses": courses,
		"lessons": lessons, "xp": lessons * xpPerLesson, "is_me": isMe,
	}
}

// MyStreak computes the caller's current daily learning streak from real
// lesson-completion dates: the run of consecutive days (ending today, or
// yesterday if nothing's done yet today) on which they completed ≥1 lesson.
func (h *Handlers) MyStreak(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(),
		`SELECT DISTINCT (completed_at AT TIME ZONE 'UTC')::date
		   FROM lesson_progress WHERE user_id = $1 ORDER BY 1 DESC`, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "streak failed")
	}
	defer rows.Close()

	const layout = "2006-01-02"
	done := map[string]bool{}
	for rows.Next() {
		var d time.Time
		if err := rows.Scan(&d); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		done[d.Format(layout)] = true
	}

	now := time.Now().UTC()
	day := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)
	todayDone := done[day.Format(layout)]
	// A streak stays alive until midnight even before today's lesson is done.
	if !todayDone {
		day = day.AddDate(0, 0, -1)
	}
	streak := 0
	for done[day.Format(layout)] {
		streak++
		day = day.AddDate(0, 0, -1)
	}
	return c.JSON(fiber.Map{"streak": streak, "today_done": todayDone})
}
