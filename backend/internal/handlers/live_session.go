package handlers

import (
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5"
)

// Live-room API for simulated-live sessions: state polling, presence heartbeats
// (real headcount), live chat and Q&A. All gated by enrollment in the session's
// course. Chat/Q&A are polled by the client — no WebSocket infra.

// liveAccess authorizes the caller for a session and returns the chat/Q&A
// toggles plus whether the caller is course STAFF (the host/admin). Access is
// granted to an enrolled student OR to course staff. pgx.ErrNoRows means not
// entitled (or no such session) → callers map it to 403.
func (h *Handlers) liveAccess(c *fiber.Ctx, sessionID string) (chatOK, qaOK, isStaff bool, err error) {
	var courseID string
	var enrolled bool
	err = h.Pool.QueryRow(c.Context(), `
		SELECT cs.chat_enabled, cs.qa_enabled, cs.course_id,
		       EXISTS(SELECT 1 FROM course_enrollments ce WHERE ce.course_id=cs.course_id AND ce.user_id=$2 AND ce.status='active')
		FROM class_sessions cs WHERE cs.id=$1`, sessionID, callerID(c)).Scan(&chatOK, &qaOK, &courseID, &enrolled)
	if err != nil {
		return
	}
	isStaff = h.canManageCourse(c, courseID) == nil || callerRole(c) == "live_host"
	if !enrolled && !isStaff {
		err = pgx.ErrNoRows
	}
	return
}

// LiveSessionState reports whether the session is upcoming/live/ended, the live
// playlist URL once live, and the (real + simulated) viewer count. The client
// polls this to flip the UI and refresh the headcount.
func (h *Handlers) LiveSessionState(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	var startsAt time.Time
	var assetID *string
	var title, course string
	var chatOK, qaOK, enrolled bool
	var hlsURL, courseID, startImg, endImg string
	var viewerBase, durationSecs int
	err := h.Pool.QueryRow(c.Context(), `
		SELECT cs.starts_at, cs.media_asset_id, cs.title, c.title,
		       cs.chat_enabled, cs.qa_enabled, cs.viewer_base, COALESCE(ma.duration_seconds, 0),
		       COALESCE(ma.hls_url,''), COALESCE(cs.start_image,''), COALESCE(cs.end_image,''), cs.course_id,
		       EXISTS(SELECT 1 FROM course_enrollments ce WHERE ce.course_id=cs.course_id AND ce.user_id=$2 AND ce.status='active')
		FROM class_sessions cs
		JOIN courses c ON c.id = cs.course_id
		LEFT JOIN media_assets ma ON ma.id = cs.media_asset_id
		WHERE cs.id = $1`, sessionID, callerID(c)).Scan(
		&startsAt, &assetID, &title, &course, &chatOK, &qaOK, &viewerBase, &durationSecs, &hlsURL, &startImg, &endImg, &courseID, &enrolled)
	if errors.Is(err, pgx.ErrNoRows) {
		return fiber.NewError(fiber.StatusForbidden, "not entitled to this session")
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "state load failed")
	}
	// Enrolled students OR course staff / a live host may view the state.
	isStaff := h.canManageCourse(c, courseID) == nil || callerRole(c) == "live_host"
	if !enrolled && !isStaff {
		return fiber.NewError(fiber.StatusForbidden, "not entitled to this session")
	}
	ready := hlsURL != ""

	now := time.Now()
	elapsed := now.Sub(startsAt).Seconds()
	status := "live"
	switch {
	case elapsed < 0:
		status = "upcoming"
	case assetID != nil && !ready:
		// Scheduled time reached but the recording is still transcoding — the
		// room waits on this instead of loading a playlist that 409s.
		status = "preparing"
	case durationSecs > 0 && elapsed >= float64(durationSecs):
		status = "ended"
	}

	// Real concurrent viewers = heartbeats in the last 30s.
	var real int
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT count(*) FROM live_presence WHERE session_id=$1 AND last_seen > now() - interval '30 seconds'`,
		sessionID).Scan(&real)

	// Simulated floor: ramp up over the first 90s ("people joining"), then drift
	// naturally around viewer_base. The drift blends several long-period sines
	// (each many minutes) so the count wanders slowly and organically by ~±20% —
	// not a fast, regular wobble. Deterministic in elapsed, so every viewer sees
	// the same number. The displayed count is max(real, sim).
	viewers := real
	if viewerBase > 0 && status == "live" {
		e := math.Max(0, elapsed)
		ramp := 1.0
		if e < 90 {
			ramp = 0.4 + 0.6*(e/90)
		}
		drift := 0.12*math.Sin(e/71) + 0.06*math.Sin(e/167+1.3) + 0.04*math.Sin(e/97+2.7)
		if sim := int(math.Round(float64(viewerBase) * ramp * (1 + drift))); sim > viewers {
			viewers = sim
		}
	}

	out := fiber.Map{
		"server_now":          now.UTC().Format(time.RFC3339),
		"starts_at":           startsAt.UTC().Format(time.RFC3339),
		"status":              status,
		"seconds_until_start": int(math.Max(0, -elapsed)),
		"elapsed":             int(math.Max(0, elapsed)),
		"duration":            durationSecs,
		"title":               title,
		"course":              course,
		"start_image":         startImg,
		"end_image":           endImg,
		"chat_enabled":        chatOK,
		"qa_enabled":          qaOK,
		"viewers":             viewers,
		"is_host":             isStaff,
	}
	// Serve the server's sliding-window LIVE playlist (h.LivePlaylist), NOT the
	// static VOD. It only ever names segments up to "now" and carries no
	// #EXT-X-ENDLIST while live, so hls.js / ExoPlayer treat it as a genuine live
	// stream: video.duration is Infinity. That is precisely what makes there be
	// NO scrubber and NO forward/back seek anywhere — not in our player, not in
	// the browser's media popup, and not in the OS / lock-screen media controls
	// (a finite VOD makes the browser render a seek bar there that we cannot
	// remove). The window is re-derived from the server clock every request, so a
	// reload resumes at the correct wall-clock second. Its AES key is the
	// auth-gated /me/live/:id/hls.key.
	if status == "live" && hlsURL != "" {
		out["playlist_url"] = h.Cfg.AppBaseURL + "/api/v1/me/live/" + sessionID + "/playlist.m3u8"
	}
	return c.JSON(out)
}

// LiveHeartbeat marks the caller present (drives the real viewer count).
func (h *Handlers) LiveHeartbeat(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	if _, _, _, err := h.liveAccess(c, sessionID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fiber.NewError(fiber.StatusForbidden, "not entitled")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "presence failed")
	}
	if _, err := h.Pool.Exec(c.Context(),
		`INSERT INTO live_presence (session_id, user_id, last_seen) VALUES ($1,$2,now())
		 ON CONFLICT (session_id, user_id) DO UPDATE SET last_seen=now()`,
		sessionID, callerID(c)); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "presence failed")
	}
	return c.JSON(fiber.Map{"ok": true})
}

// LiveChatList returns chat ascending. With ?after=<rfc3339> it returns only
// newer messages (the client passes the last message's timestamp as the cursor).
func (h *Handlers) LiveChatList(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	_, _, isStaff, err := h.liveAccess(c, sessionID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fiber.NewError(fiber.StatusForbidden, "not entitled")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "chat load failed")
	}
	after := strings.TrimSpace(c.Query("after"))
	// Privacy: staff (the host) see every message; a student sees only the host's
	// broadcasts plus their own messages — never other students'.
	args := []any{sessionID}
	vis := ""
	if !isStaff {
		args = append(args, callerID(c))
		vis = " AND (from_staff = true OR user_id = $2)"
	}
	out := []fiber.Map{}
	var rows pgx.Rows
	if after != "" {
		args = append(args, after)
		cur := len(args) // $ index of the cursor
		rows, err = h.Pool.Query(c.Context(), fmt.Sprintf(
			`SELECT id, user_id, display_name, body, from_staff, created_at FROM live_chat_messages
			 WHERE session_id=$1%s AND created_at > $%d::timestamptz ORDER BY created_at ASC LIMIT 200`, vis, cur),
			args...)
	} else {
		rows, err = h.Pool.Query(c.Context(), fmt.Sprintf(
			`SELECT id, user_id, display_name, body, from_staff, created_at FROM (
			   SELECT id, user_id, display_name, body, from_staff, created_at FROM live_chat_messages
			   WHERE session_id=$1%s ORDER BY created_at DESC LIMIT 100
			 ) t ORDER BY created_at ASC`, vis),
			args...)
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "chat load failed")
	}
	defer rows.Close()
	for rows.Next() {
		var id, uid, name, body string
		var fromStaff bool
		var at time.Time
		if err := rows.Scan(&id, &uid, &name, &body, &fromStaff, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "user_id": uid, "name": name, "body": body, "from_staff": fromStaff, "at": at.UTC().Format(time.RFC3339Nano)})
	}
	return c.JSON(fiber.Map{"messages": out})
}

// LiveChatPost adds a chat message (gated on chat_enabled).
func (h *Handlers) LiveChatPost(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	chatOK, _, isStaff, err := h.liveAccess(c, sessionID)
	if errors.Is(err, pgx.ErrNoRows) {
		return fiber.NewError(fiber.StatusForbidden, "not entitled")
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "chat failed")
	}
	if !chatOK {
		return fiber.NewError(fiber.StatusForbidden, "chat is disabled")
	}
	body, perr := parseLiveBody(c)
	if perr != nil {
		return perr
	}
	// from_staff marks a host message (broadcast to everyone); a student message
	// is private to the host.
	var id, name string
	var at time.Time
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO live_chat_messages (session_id, user_id, display_name, body, from_staff)
		 VALUES ($1, $2, COALESCE((SELECT full_name FROM users WHERE id=$2), ''), $3, $4)
		 RETURNING id, display_name, created_at`,
		sessionID, callerID(c), body, isStaff).Scan(&id, &name, &at); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "post failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{
		"id": id, "user_id": callerID(c), "name": name, "body": body, "from_staff": isStaff, "at": at.UTC().Format(time.RFC3339Nano)})
}

// LiveChatDelete removes a chat message. Allowed for its author, or for staff
// who can manage the session's course (moderation).
func (h *Handlers) LiveChatDelete(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	msgID := c.Params("msgId")
	var authorID, courseID string
	err := h.Pool.QueryRow(c.Context(),
		`SELECT m.user_id, cs.course_id
		 FROM live_chat_messages m JOIN class_sessions cs ON cs.id = m.session_id
		 WHERE m.id = $1 AND m.session_id = $2`, msgID, sessionID).Scan(&authorID, &courseID)
	if errors.Is(err, pgx.ErrNoRows) {
		return fiber.NewError(fiber.StatusNotFound, "message not found")
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	// The author can always delete their own; otherwise the caller must be able
	// to manage the course (instructor/manager) to moderate someone else's.
	if authorID != callerID(c) {
		if cerr := h.canManageCourse(c, courseID); cerr != nil {
			return fiber.NewError(fiber.StatusForbidden, "cannot delete this message")
		}
	}
	if _, err := h.Pool.Exec(c.Context(), `DELETE FROM live_chat_messages WHERE id=$1`, msgID); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "delete failed")
	}
	return c.JSON(fiber.Map{"deleted": true, "id": msgID})
}

// LiveQuestionsList returns the Q&A. Staff (the host) get EVERY question — the
// queue to answer, unanswered first. A student sees only their own questions,
// each with the host's answer once given.
func (h *Handlers) LiveQuestionsList(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	_, _, isStaff, err := h.liveAccess(c, sessionID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return fiber.NewError(fiber.StatusForbidden, "not entitled")
		}
		return fiber.NewError(fiber.StatusInternalServerError, "questions load failed")
	}
	var rows pgx.Rows
	if isStaff {
		// Queue: unanswered first (oldest first), then answered (newest first).
		rows, err = h.Pool.Query(c.Context(),
			`SELECT id, user_id, display_name, body, answer, answered, created_at FROM live_questions
			 WHERE session_id=$1 ORDER BY answered ASC, (CASE WHEN answered THEN created_at END) DESC, created_at ASC LIMIT 300`, sessionID)
	} else {
		rows, err = h.Pool.Query(c.Context(),
			`SELECT id, user_id, display_name, body, answer, answered, created_at FROM live_questions
			 WHERE session_id=$1 AND user_id=$2 ORDER BY created_at DESC LIMIT 200`, sessionID, callerID(c))
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "questions load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, uid, name, body, answer string
		var answered bool
		var at time.Time
		if err := rows.Scan(&id, &uid, &name, &body, &answer, &answered, &at); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "user_id": uid, "name": name, "body": body, "answer": answer, "answered": answered, "at": at.UTC().Format(time.RFC3339Nano)})
	}
	return c.JSON(fiber.Map{"questions": out})
}

// LiveAnswerQuestion lets the host (course staff) answer a specific question.
// The answer is delivered to the student who asked.
func (h *Handlers) LiveAnswerQuestion(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	qid := c.Params("qid")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM class_sessions WHERE id=$1`, sessionID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "session not found")
	}
	if h.canManageCourse(c, courseID) != nil && callerRole(c) != "live_host" {
		return fiber.NewError(fiber.StatusForbidden, "only the host can answer")
	}
	body, perr := parseLiveBody(c)
	if perr != nil {
		return perr
	}
	ct, err := h.Pool.Exec(c.Context(),
		`UPDATE live_questions SET answer=$3, answered=true, answered_at=now(), answered_by=$4
		 WHERE id=$1 AND session_id=$2`, qid, sessionID, body, callerID(c))
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "answer failed")
	}
	if ct.RowsAffected() == 0 {
		return fiber.NewError(fiber.StatusNotFound, "question not found")
	}
	return c.JSON(fiber.Map{"id": qid, "answer": body, "answered": true})
}

// LiveQuestionPost submits a question (gated on qa_enabled).
func (h *Handlers) LiveQuestionPost(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	_, qaOK, _, err := h.liveAccess(c, sessionID)
	if errors.Is(err, pgx.ErrNoRows) {
		return fiber.NewError(fiber.StatusForbidden, "not entitled")
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "question failed")
	}
	if !qaOK {
		return fiber.NewError(fiber.StatusForbidden, "Q&A is disabled")
	}
	body, perr := parseLiveBody(c)
	if perr != nil {
		return perr
	}
	var id, name string
	var at time.Time
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO live_questions (session_id, user_id, display_name, body)
		 VALUES ($1, $2, COALESCE((SELECT full_name FROM users WHERE id=$2), ''), $3)
		 RETURNING id, display_name, created_at`,
		sessionID, callerID(c), body).Scan(&id, &name, &at); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "post failed")
	}
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{
		"id": id, "user_id": callerID(c), "name": name, "body": body, "answered": false, "at": at.UTC().Format(time.RFC3339Nano)})
}

// ListLiveHostSessions lists the simulated-live sessions for the live-host
// portal (recent + upcoming), each with its count of unanswered questions.
func (h *Handlers) ListLiveHostSessions(c *fiber.Ctx) error {
	rows, err := h.Pool.Query(c.Context(), `
		SELECT cs.id, cs.title, c.title, cs.starts_at,
		       cs.starts_at + make_interval(secs => COALESCE(ma.duration_seconds,0)) AS ends_at,
		       (SELECT count(*) FROM live_questions q WHERE q.session_id=cs.id AND NOT q.answered) AS waiting
		FROM class_sessions cs
		JOIN courses c ON c.id = cs.course_id
		JOIN media_assets ma ON ma.id = cs.media_asset_id
		WHERE cs.media_asset_id IS NOT NULL AND cs.starts_at >= now() - interval '2 days'
		ORDER BY cs.starts_at`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title, course string
		var startsAt, endsAt any
		var waiting int
		if err := rows.Scan(&id, &title, &course, &startsAt, &endsAt, &waiting); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "course": course, "starts_at": startsAt, "ends_at": endsAt, "waiting": waiting})
	}
	return c.JSON(fiber.Map{"sessions": out})
}

// parseLiveBody pulls a non-empty {body} from the request, capped at 1000 chars.
func parseLiveBody(c *fiber.Ctx) (string, error) {
	var req struct {
		Body string `json:"body"`
	}
	if err := c.BodyParser(&req); err != nil {
		return "", fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	body := strings.TrimSpace(req.Body)
	if body == "" {
		return "", fiber.NewError(fiber.StatusBadRequest, "empty message")
	}
	if len(body) > 1000 {
		body = body[:1000]
	}
	return body, nil
}
