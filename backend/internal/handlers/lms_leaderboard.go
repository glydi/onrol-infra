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
	// Course-scoped board when ?course_id is given; otherwise the overall XP board.
	if courseID := c.Query("course_id"); courseID != "" {
		return h.courseLeaderboard(c, me, courseID)
	}
	rows, err := h.Pool.Query(c.Context(), `
		WITH per_user AS (
		  SELECT u.id, u.full_name, COALESCE(u.username,'') AS username,
		         COALESCE(u.avatar,'') AS avatar,
		         COUNT(lp.lesson_id) AS lessons,
		         COALESCE((SELECT ROUND(SUM(s.score)) FROM submissions s
		                   WHERE s.user_id = u.id AND s.score IS NOT NULL),0)::int AS quiz_xp
		  FROM users u
		  LEFT JOIN lesson_progress lp ON lp.user_id = u.id
		  WHERE u.role = 'student'
		  GROUP BY u.id, u.full_name, u.username, u.avatar
		)
		SELECT pu.id, pu.full_name, pu.username, pu.avatar, pu.lessons, pu.quiz_xp,
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
		ORDER BY (pu.lessons * 10 + pu.quiz_xp) DESC, pu.full_name ASC
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
		var lessons, quizXP, courses int
		if err := rows.Scan(&id, &name, &username, &avatar, &lessons, &quizXP, &topCourse, &courses); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		rank++
		isMe := id == me
		if isMe {
			myRank = rank
		}
		out = append(out, leaderRow(rank, name, username, avatar, topCourse, lessons, courses, quizXP, isMe))
	}

	// If the caller isn't in the top slice, append their own row with their true
	// rank so they can always see where they stand.
	if myRank == 0 {
		var name, username, avatar, topCourse string
		var lessons, quizXP, courses, rnk int
		err := h.Pool.QueryRow(c.Context(), `
			SELECT u.full_name, COALESCE(u.username,''), COALESCE(u.avatar,''),
			  (SELECT count(*) FROM lesson_progress lp WHERE lp.user_id = u.id),
			  COALESCE((SELECT ROUND(SUM(s.score)) FROM submissions s
			            WHERE s.user_id = u.id AND s.score IS NOT NULL),0)::int,
			  (SELECT count(*) FROM course_enrollments ce WHERE ce.user_id = u.id),
			  1 + (SELECT count(*) FROM (
			        SELECT u2.id,
			               count(lp2.lesson_id)*10 + COALESCE((SELECT ROUND(SUM(s2.score))
			                 FROM submissions s2 WHERE s2.user_id = u2.id AND s2.score IS NOT NULL),0) AS xp
			        FROM users u2
			        LEFT JOIN lesson_progress lp2 ON lp2.user_id = u2.id
			        WHERE u2.role = 'student' GROUP BY u2.id
			      ) t WHERE t.xp > (
			        (SELECT count(*) FROM lesson_progress WHERE user_id = u.id)*10
			        + COALESCE((SELECT ROUND(SUM(s3.score)) FROM submissions s3
			                    WHERE s3.user_id = u.id AND s3.score IS NOT NULL),0))),
			  COALESCE((
			    SELECT c.title FROM course_enrollments ce JOIN courses c ON c.id = ce.course_id
			    WHERE ce.user_id = u.id ORDER BY ce.enrolled_at DESC LIMIT 1
			  ), '')
			FROM users u WHERE u.id = $1`, me).
			Scan(&name, &username, &avatar, &lessons, &quizXP, &courses, &rnk, &topCourse)
		if err == nil && name != "" {
			myRank = rnk
			out = append(out, leaderRow(rnk, name, username, avatar, topCourse, lessons, courses, quizXP, true))
		}
	}

	return c.JSON(fiber.Map{"leaderboard": out, "my_rank": myRank})
}

func leaderRow(rank int, name, username, avatar, course string, lessons, courses, quizXP int, isMe bool) fiber.Map {
	return fiber.Map{
		"rank": rank, "name": name, "username": username, "avatar": avatar,
		"course": course, "courses": courses,
		"lessons": lessons, "quiz_xp": quizXP,
		"xp": lessons*xpPerLesson + quizXP, "is_me": isMe,
	}
}

// courseLeaderboard ranks the students enrolled in one course by the lessons
// they've completed in that course (XP = lessons*10 within the course).
func (h *Handlers) courseLeaderboard(c *fiber.Ctx, me, courseID string) error {
	var title string
	if err := h.Pool.QueryRow(c.Context(), `SELECT title FROM courses WHERE id=$1`, courseID).Scan(&title); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "course not found")
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT u.id, u.full_name, COALESCE(u.username,''), COALESCE(u.avatar,''),
		  (SELECT count(*) FROM lesson_progress lp
		     JOIN lessons l ON l.id = lp.lesson_id
		     JOIN modules m ON m.id = l.module_id
		     WHERE m.course_id = $1 AND lp.user_id = u.id) AS lessons,
		  COALESCE((SELECT ROUND(SUM(s.score)) FROM submissions s
		     JOIN assessments a ON a.id = s.assessment_id
		     WHERE a.course_id = $1 AND s.user_id = u.id AND s.score IS NOT NULL),0)::int AS quiz_xp
		FROM users u
		WHERE u.role = 'student'
		  AND EXISTS (SELECT 1 FROM course_enrollments ce WHERE ce.course_id = $1 AND ce.user_id = u.id)
		ORDER BY (lessons * 10 + (SELECT COALESCE(ROUND(SUM(s.score)),0) FROM submissions s
		     JOIN assessments a ON a.id = s.assessment_id
		     WHERE a.course_id = $1 AND s.user_id = u.id AND s.score IS NOT NULL)) DESC, u.full_name ASC
		LIMIT 25`, courseID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "leaderboard failed")
	}
	defer rows.Close()

	out := []fiber.Map{}
	myRank := 0
	rank := 0
	for rows.Next() {
		var id, name, username, avatar string
		var lessons, quizXP int
		if err := rows.Scan(&id, &name, &username, &avatar, &lessons, &quizXP); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		rank++
		isMe := id == me
		if isMe {
			myRank = rank
		}
		out = append(out, leaderRow(rank, name, username, avatar, title, lessons, 1, quizXP, isMe))
	}

	// Append the caller with their true in-course rank if they're enrolled but
	// fell outside the top slice.
	if myRank == 0 {
		var name, username, avatar string
		var lessons, quizXP, rnk int
		err := h.Pool.QueryRow(c.Context(), `
			SELECT u.full_name, COALESCE(u.username,''), COALESCE(u.avatar,''),
			  (SELECT count(*) FROM lesson_progress lp
			     JOIN lessons l ON l.id = lp.lesson_id JOIN modules m ON m.id = l.module_id
			     WHERE m.course_id = $2 AND lp.user_id = u.id),
			  COALESCE((SELECT ROUND(SUM(s.score)) FROM submissions s
			     JOIN assessments a ON a.id = s.assessment_id
			     WHERE a.course_id = $2 AND s.user_id = u.id AND s.score IS NOT NULL),0)::int,
			  1 + (SELECT count(*) FROM (
			        SELECT u2.id,
			          (SELECT count(*) FROM lesson_progress lp2
			             JOIN lessons l2 ON l2.id = lp2.lesson_id JOIN modules m2 ON m2.id = l2.module_id
			             WHERE m2.course_id = $2 AND lp2.user_id = u2.id)*10
			          + COALESCE((SELECT ROUND(SUM(s2.score)) FROM submissions s2
			             JOIN assessments a2 ON a2.id = s2.assessment_id
			             WHERE a2.course_id = $2 AND s2.user_id = u2.id AND s2.score IS NOT NULL),0) AS xp
			        FROM users u2
			        WHERE u2.role = 'student'
			          AND EXISTS (SELECT 1 FROM course_enrollments ce WHERE ce.course_id = $2 AND ce.user_id = u2.id)
			      ) t WHERE t.xp > (
			        (SELECT count(*) FROM lesson_progress lp3
			           JOIN lessons l3 ON l3.id = lp3.lesson_id JOIN modules m3 ON m3.id = l3.module_id
			           WHERE m3.course_id = $2 AND lp3.user_id = u.id)*10
			        + COALESCE((SELECT ROUND(SUM(s3.score)) FROM submissions s3
			           JOIN assessments a3 ON a3.id = s3.assessment_id
			           WHERE a3.course_id = $2 AND s3.user_id = u.id AND s3.score IS NOT NULL),0)))
			FROM users u
			WHERE u.id = $1
			  AND EXISTS (SELECT 1 FROM course_enrollments ce WHERE ce.course_id = $2 AND ce.user_id = u.id)`,
			me, courseID).Scan(&name, &username, &avatar, &lessons, &quizXP, &rnk)
		if err == nil && name != "" {
			myRank = rnk
			out = append(out, leaderRow(rnk, name, username, avatar, title, lessons, 1, quizXP, true))
		}
	}

	return c.JSON(fiber.Map{"leaderboard": out, "my_rank": myRank, "course": title})
}

// MyStreak records today's check-in (the caller just opened the app) and returns
// the current daily streak: the run of consecutive days — in the user's OWN
// timezone, not UTC — on which they checked in, ending today. This is a real
// "show up every day" streak backed by the user_checkins table, not tied to
// completing a lesson.
func (h *Handlers) MyStreak(c *fiber.Ctx) error {
	uid := callerID(c)

	// "Today" in the user's timezone (default Asia/Kolkata) so the day boundary
	// is their real midnight, not UTC's.
	tz := "Asia/Kolkata"
	_ = h.Pool.QueryRow(c.Context(), `SELECT timezone FROM user_preferences WHERE user_id=$1`, uid).Scan(&tz)
	loc, err := time.LoadLocation(tz)
	if err != nil {
		loc = time.UTC
	}
	now := time.Now().In(loc)
	const layout = "2006-01-02"
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, loc)

	// Record today's check-in (idempotent: one row per user per local day).
	_, _ = h.Pool.Exec(c.Context(),
		`INSERT INTO user_checkins (user_id, day) VALUES ($1,$2) ON CONFLICT DO NOTHING`,
		uid, today.Format(layout))

	rows, err := h.Pool.Query(c.Context(),
		`SELECT day FROM user_checkins WHERE user_id = $1 ORDER BY day DESC`, uid)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "streak failed")
	}
	defer rows.Close()

	done := map[string]bool{}
	for rows.Next() {
		var d time.Time
		if err := rows.Scan(&d); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		done[d.Format(layout)] = true
	}

	day := today
	todayDone := done[day.Format(layout)]
	// A streak stays alive until midnight even if they haven't checked in yet
	// (defensive — we just inserted today, so this is normally true).
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
