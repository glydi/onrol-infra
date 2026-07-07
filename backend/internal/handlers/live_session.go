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
// playlist URL once live, and the (real + simulated) viewer count. Every viewer
// polls this; the shared block is cached per session (~2s) so 3000 pollers cost
// one recompute, and the per-user auth + is_host come from the access cache — so
// a cache-hit poll does no DB work at all.
func (h *Handlers) LiveSessionState(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	_, _, _, isStaff, allowed := h.liveAccessCached(c, sessionID)
	if !allowed {
		return fiber.NewError(fiber.StatusForbidden, "not entitled to this session")
	}
	shared, ferr := h.cachedLiveState(c, sessionID)
	if ferr != nil {
		return ferr
	}
	out := make(fiber.Map, len(shared)+1)
	for k, v := range shared {
		out[k] = v
	}
	out["is_host"] = isStaff
	return c.JSON(out)
}

// cachedLiveState returns the per-session shared state block, recomputing at
// most once per stateTTL. The returned map is read-only (the handler copies it
// before adding per-user fields).
func (h *Handlers) cachedLiveState(c *fiber.Ctx, sessionID string) (fiber.Map, *fiber.Error) {
	now := time.Now()
	stateMu.Lock()
	if e, ok := stateCache[sessionID]; ok && now.Before(e.exp) {
		stateMu.Unlock()
		return e.data, nil
	}
	stateMu.Unlock()

	data, ferr := h.buildLiveState(c, sessionID, now)
	if ferr != nil {
		return nil, ferr
	}
	stateMu.Lock()
	stateCache[sessionID] = stateEntry{data: data, exp: now.Add(stateTTL)}
	stateMu.Unlock()
	return data, nil
}

// buildLiveState does the actual (session-shared) work: load the session row,
// derive status, compute the headcount from in-memory presence + the simulated
// floor, and fold in the pending reaction batch.
func (h *Handlers) buildLiveState(c *fiber.Ctx, sessionID string, now time.Time) (fiber.Map, *fiber.Error) {
	var startsAt time.Time
	var assetID *string
	var pausedAt, manualEnd *time.Time
	var title, course, hlsURL, startImg, endImg, banner string
	var chatOK, qaOK, reactOK, blank, muted bool
	var viewerBase, durationSecs, reloadSeq, slidesRev, slideshowSecs int
	var currentSlide *string
	var slideshowAt *time.Time
	err := h.Pool.QueryRow(c.Context(), `
		SELECT cs.starts_at, cs.media_asset_id, cs.title, c.title,
		       cs.chat_enabled, cs.qa_enabled, cs.reactions_enabled, cs.viewer_base, COALESCE(ma.duration_seconds, 0),
		       COALESCE(ma.hls_url,''), COALESCE(cs.start_image,''), COALESCE(cs.end_image,''),
		       cs.paused_at, cs.blank, cs.muted, cs.banner, cs.manual_ended_at, cs.reload_seq,
		       cs.current_slide_id, cs.slides_rev, cs.slideshow_at, cs.slideshow_secs
		FROM class_sessions cs
		JOIN courses c ON c.id = cs.course_id
		LEFT JOIN media_assets ma ON ma.id = cs.media_asset_id
		WHERE cs.id = $1`, sessionID).Scan(
		&startsAt, &assetID, &title, &course, &chatOK, &qaOK, &reactOK, &viewerBase, &durationSecs,
		&hlsURL, &startImg, &endImg, &pausedAt, &blank, &muted, &banner, &manualEnd, &reloadSeq,
		&currentSlide, &slidesRev, &slideshowAt, &slideshowSecs)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, fiber.NewError(fiber.StatusForbidden, "not entitled to this session")
	}
	if err != nil {
		return nil, fiber.NewError(fiber.StatusInternalServerError, "state load failed")
	}
	ready := hlsURL != ""

	// When paused, effective elapsed freezes at the pause moment (on resume the
	// control handler shifts starts_at forward so this keeps flowing correctly).
	paused := pausedAt != nil
	elapsed := now.Sub(startsAt).Seconds()
	if paused {
		elapsed = pausedAt.Sub(startsAt).Seconds()
	}
	status := "live"
	switch {
	case elapsed < 0:
		status = "upcoming"
	case manualEnd != nil && !manualEnd.After(now):
		status = "ended" // host ended it early
	case assetID != nil && !ready:
		// Scheduled time reached but the recording is still transcoding — the
		// room waits on this instead of loading a playlist that 409s.
		status = "preparing"
	case durationSecs > 0 && elapsed >= float64(durationSecs):
		status = "ended"
	}

	// The presented slide: an auto slideshow (deterministic by elapsed time so all
	// viewers are in sync) when running, else whatever slide was manually pinned.
	curSlide := ""
	if currentSlide != nil {
		curSlide = *currentSlide
	}
	if slideshowAt != nil {
		var ids []string
		if rows, qerr := h.Pool.Query(c.Context(), `SELECT id FROM live_slides WHERE session_id=$1 ORDER BY position, created_at`, sessionID); qerr == nil {
			for rows.Next() {
				var id string
				if rows.Scan(&id) == nil {
					ids = append(ids, id)
				}
			}
			rows.Close()
		}
		if len(ids) > 0 {
			secs := slideshowSecs
			if secs < 2 {
				secs = 2
			}
			e := int(now.Sub(*slideshowAt).Seconds())
			if e < 0 {
				e = 0
			}
			curSlide = ids[(e/secs)%len(ids)]
		}
	}

	// Real concurrent viewers = in-memory heartbeats in the last 30s.
	real := presenceCount(sessionID, 30*time.Second)

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
		"reactions_enabled":   reactOK,
		"viewers":             viewers,
		"paused":              paused,
		"blank":               blank,
		"muted":               muted,
		"banner":              banner,
		"reload_seq":          reloadSeq,
		"current_slide_id":    curSlide,
		"slides_rev":          slidesRev,
		"slideshow":           slideshowAt != nil,
	}
	// Reaction batch since the last rebuild — rides along on the state everyone
	// already polls, so reactions reach the whole room with no extra requests.
	if reMap, reSeq := snapshotReactions(sessionID); reSeq > 0 {
		if len(reMap) > 0 {
			out["reactions"] = reMap
		}
		out["reactions_seq"] = reSeq
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
	return out, nil
}

// LiveHeartbeat marks the caller present (drives the real viewer count). Auth is
// cached and presence is in-memory, so this touches no database.
func (h *Handlers) LiveHeartbeat(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	if _, _, _, _, allowed := h.liveAccessCached(c, sessionID); !allowed {
		return fiber.NewError(fiber.StatusForbidden, "not entitled")
	}
	touchPresence(sessionID, callerID(c))
	return c.JSON(fiber.Map{"ok": true})
}

// LiveReact records a floating reaction (👍👏❤️😂😮🎉🚀👌). It's an in-memory
// tally with no DB write; the batch is broadcast to the room on the next /state
// poll everyone already makes, so reactions add no new polling load.
func (h *Handlers) LiveReact(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	_, _, reactOK, isStaff, allowed := h.liveAccessCached(c, sessionID)
	if !allowed {
		return fiber.NewError(fiber.StatusForbidden, "not entitled")
	}
	if !reactOK && !isStaff {
		return fiber.NewError(fiber.StatusForbidden, "reactions are off")
	}
	var req struct {
		Emoji string `json:"emoji"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	emoji, ok := normalizeReaction(req.Emoji)
	if !ok {
		return fiber.NewError(fiber.StatusBadRequest, "unknown reaction")
	}
	addReaction(sessionID, emoji)
	bumpReaction(sessionID, callerID(c)) // count toward the sender's attendance engagement
	return c.JSON(fiber.Map{"ok": true})
}

// LiveControl lets the host (course staff) drive the room: pause/resume,
// black-out, mute-all, banner, reactions/chat/Q&A toggles, and start/end-now.
// Only the fields present in the body are applied. Pause is time-locked-safe —
// resuming shifts starts_at forward by the paused duration so the wall-clock
// position is preserved. Caches are invalidated so viewers see it next poll.
func (h *Handlers) LiveControl(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM class_sessions WHERE id=$1`, sessionID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "session not found")
	}
	if h.canManageCourse(c, courseID) != nil && callerRole(c) != "live_host" {
		return fiber.NewError(fiber.StatusForbidden, "only the host can control the room")
	}

	// All fields optional; nil = leave unchanged.
	var req struct {
		Paused    *bool   `json:"paused"`
		Blank     *bool   `json:"blank"`
		Muted     *bool   `json:"muted"`
		Banner    *string `json:"banner"`
		Chat      *bool   `json:"chat_enabled"`
		QA        *bool   `json:"qa_enabled"`
		Reactions *bool   `json:"reactions_enabled"`
		StartNow  bool    `json:"start_now"`
		EndNow    bool    `json:"end_now"`
		SeekTo    *int    `json:"seek_to"`       // seconds into the recording to jump to
		SwitchTo  *string `json:"switch_to"`     // media_asset_id to switch the class to
		Present   *string `json:"present_slide"` // slide id to show over the video ("" = stop)
		Slideshow *bool   `json:"slideshow"`     // start/stop the auto slideshow
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}

	// Switching the video is validated up front: the target must be a ready,
	// transcoded asset or the live stream would 409 for everyone.
	if req.SwitchTo != nil && *req.SwitchTo != "" {
		var ready bool
		if err := h.Pool.QueryRow(c.Context(),
			`SELECT status='ready' AND hls_url<>'' FROM media_assets WHERE id=$1`, *req.SwitchTo).Scan(&ready); err != nil || !ready {
			return fiber.NewError(fiber.StatusBadRequest, "that video isn't ready to stream")
		}
	}

	sets := []string{}
	args := []any{sessionID}
	bumpReload := false // set when the position jumps → clients re-init their player
	add := func(expr string, val any) {
		args = append(args, val)
		sets = append(sets, fmt.Sprintf("%s=$%d", expr, len(args)))
	}
	if req.StartNow {
		// Go live right now: start the clock, clear pause/end.
		sets = append(sets, "starts_at=now()", "paused_at=NULL", "manual_ended_at=NULL")
		bumpReload = true
	}
	if req.SeekTo != nil {
		// Jump the live position to `seek_to` seconds in. When paused, anchor off
		// paused_at so it stays frozen at the new spot; otherwise off now().
		t := *req.SeekTo
		if t < 0 {
			t = 0
		}
		args = append(args, t)
		sets = append(sets, fmt.Sprintf("starts_at = COALESCE(paused_at, now()) - make_interval(secs => $%d)", len(args)))
		sets = append(sets, "manual_ended_at=NULL") // seeking to a mid-point means it's live again
		bumpReload = true
	}
	if req.EndNow {
		sets = append(sets, "manual_ended_at=now()", "paused_at=NULL")
	}
	if req.SwitchTo != nil && *req.SwitchTo != "" {
		// Play a different recording from its start; clear pause / end / black-out.
		args = append(args, *req.SwitchTo)
		sets = append(sets, fmt.Sprintf("media_asset_id=$%d", len(args)))
		sets = append(sets, "starts_at=now()", "paused_at=NULL", "manual_ended_at=NULL", "blank=false")
		bumpReload = true
	}
	if req.Paused != nil && !req.StartNow {
		if *req.Paused {
			sets = append(sets, "paused_at=COALESCE(paused_at, now())") // idempotent pause
		} else {
			// Resume: advance the schedule by however long we were paused, then clear.
			sets = append(sets, "starts_at=starts_at + (now() - COALESCE(paused_at, now()))", "paused_at=NULL")
		}
	}
	if req.Blank != nil {
		add("blank", *req.Blank)
	}
	if req.Muted != nil {
		add("muted", *req.Muted)
	}
	if req.Banner != nil {
		b := *req.Banner
		if len(b) > 300 {
			b = b[:300]
		}
		add("banner", b)
	}
	if req.Chat != nil {
		add("chat_enabled", *req.Chat)
	}
	if req.QA != nil {
		add("qa_enabled", *req.QA)
	}
	if req.Reactions != nil {
		add("reactions_enabled", *req.Reactions)
	}
	if req.Present != nil {
		if *req.Present == "" {
			sets = append(sets, "current_slide_id=NULL") // stop presenting
		} else {
			add("current_slide_id", *req.Present)
		}
	}
	if req.Slideshow != nil {
		if *req.Slideshow {
			sets = append(sets, "slideshow_at=now()", "current_slide_id=NULL") // start auto slideshow
		} else {
			sets = append(sets, "slideshow_at=NULL")
		}
	}
	if bumpReload {
		sets = append(sets, "reload_seq = reload_seq + 1")
	}
	if len(sets) == 0 {
		return fiber.NewError(fiber.StatusBadRequest, "no control fields")
	}

	if _, err := h.Pool.Exec(c.Context(),
		fmt.Sprintf("UPDATE class_sessions SET %s WHERE id=$1", strings.Join(sets, ", ")), args...); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "control update failed")
	}
	invalidateLiveCaches(sessionID)
	return c.JSON(fiber.Map{"ok": true})
}

// LiveSlidesList returns the session's image album (data URIs) — fetched by
// every viewer when slides_rev changes, so it stays off the polled /state.
func (h *Handlers) LiveSlidesList(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	if _, _, _, _, allowed := h.liveAccessCached(c, sessionID); !allowed {
		return fiber.NewError(fiber.StatusForbidden, "not entitled")
	}
	rows, err := h.Pool.Query(c.Context(),
		`SELECT id, image FROM live_slides WHERE session_id=$1 ORDER BY position, created_at`, sessionID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "slides load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, image string
		if err := rows.Scan(&id, &image); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "image": image})
	}
	return c.JSON(fiber.Map{"slides": out})
}

// LiveSlideAdd appends an image to the album (host-only); bumps slides_rev.
func (h *Handlers) LiveSlideAdd(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	if ferr := h.requireLiveHost(c, sessionID); ferr != nil {
		return ferr
	}
	var req struct {
		Image string `json:"image"`
	}
	if err := c.BodyParser(&req); err != nil {
		return fiber.NewError(fiber.StatusBadRequest, "invalid body")
	}
	img := strings.TrimSpace(req.Image)
	if !strings.HasPrefix(img, "data:image/") {
		return fiber.NewError(fiber.StatusBadRequest, "expected an image data URI")
	}
	if len(img) > 8_000_000 { // ~6 MB decoded — plenty for a slide
		return fiber.NewError(fiber.StatusRequestEntityTooLarge, "image too large")
	}
	var id string
	if err := h.Pool.QueryRow(c.Context(),
		`INSERT INTO live_slides (session_id, image, position)
		 VALUES ($1, $2, COALESCE((SELECT MAX(position)+1 FROM live_slides WHERE session_id=$1), 0))
		 RETURNING id`, sessionID, img).Scan(&id); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "add failed")
	}
	_, _ = h.Pool.Exec(c.Context(), `UPDATE class_sessions SET slides_rev = slides_rev + 1 WHERE id=$1`, sessionID)
	invalidateLiveCaches(sessionID)
	return c.Status(fiber.StatusCreated).JSON(fiber.Map{"id": id})
}

// LiveSlideDelete removes a slide (host-only); clears it if it was being shown.
func (h *Handlers) LiveSlideDelete(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	if ferr := h.requireLiveHost(c, sessionID); ferr != nil {
		return ferr
	}
	slideID := c.Params("slideId")
	_, _ = h.Pool.Exec(c.Context(), `DELETE FROM live_slides WHERE id=$1 AND session_id=$2`, slideID, sessionID)
	_, _ = h.Pool.Exec(c.Context(),
		`UPDATE class_sessions
		 SET slides_rev = slides_rev + 1,
		     current_slide_id = CASE WHEN current_slide_id=$2 THEN NULL ELSE current_slide_id END
		 WHERE id=$1`, sessionID, slideID)
	invalidateLiveCaches(sessionID)
	return c.JSON(fiber.Map{"deleted": true, "id": slideID})
}

// requireLiveHost gates an action to the session's course staff / live host.
func (h *Handlers) requireLiveHost(c *fiber.Ctx, sessionID string) *fiber.Error {
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM class_sessions WHERE id=$1`, sessionID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "session not found")
	}
	if h.canManageCourse(c, courseID) != nil && callerRole(c) != "live_host" {
		return fiber.NewError(fiber.StatusForbidden, "only the host can do that")
	}
	return nil
}

// LiveSwitchableVideos lists the ready recordings the host can switch the class
// to (staff-only), newest first. Used by the in-room "Switch video" picker.
func (h *Handlers) LiveSwitchableVideos(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM class_sessions WHERE id=$1`, sessionID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "session not found")
	}
	if h.canManageCourse(c, courseID) != nil && callerRole(c) != "live_host" {
		return fiber.NewError(fiber.StatusForbidden, "only the host can switch the video")
	}
	rows, err := h.Pool.Query(c.Context(), `
		SELECT id, title, COALESCE(duration_seconds, 0)
		FROM media_assets WHERE status='ready' AND hls_url<>''
		ORDER BY created_at DESC LIMIT 500`)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "list failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	for rows.Next() {
		var id, title string
		var dur int
		if err := rows.Scan(&id, &title, &dur); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		out = append(out, fiber.Map{"id": id, "title": title, "duration_seconds": dur})
	}
	return c.JSON(fiber.Map{"videos": out})
}

// LiveAttendance returns who watched a session and for how long (staff-only).
// It flushes the pending in-memory watch-time first so the numbers are current.
func (h *Handlers) LiveAttendance(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	var courseID string
	if err := h.Pool.QueryRow(c.Context(), `SELECT course_id FROM class_sessions WHERE id=$1`, sessionID).Scan(&courseID); err != nil {
		return fiber.NewError(fiber.StatusNotFound, "session not found")
	}
	if h.canManageCourse(c, courseID) != nil && callerRole(c) != "live_host" {
		return fiber.NewError(fiber.StatusForbidden, "only the host can view attendance")
	}
	h.flushAttendance(sessionID) // persist the latest in-memory watch-time first

	// Session length (for % watched) and totals for the summary header.
	var durationSecs int
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(ma.duration_seconds,0) FROM class_sessions cs LEFT JOIN media_assets ma ON ma.id=cs.media_asset_id WHERE cs.id=$1`,
		sessionID).Scan(&durationSecs)

	rows, err := h.Pool.Query(c.Context(), `
		SELECT COALESCE(u.full_name,''), COALESCE(u.email,''), COALESCE(u.phone,''), COALESCE(u.login_id,''),
		       a.first_seen, a.last_seen, a.watched_seconds, a.reactions_sent,
		       (SELECT count(*) FROM live_questions q WHERE q.session_id=$1 AND q.user_id=a.user_id) AS questions
		FROM live_attendance a JOIN users u ON u.id = a.user_id
		WHERE a.session_id = $1
		ORDER BY a.watched_seconds DESC, u.full_name ASC`, sessionID)
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "attendance load failed")
	}
	defer rows.Close()
	out := []fiber.Map{}
	var totalWatch int64
	for rows.Next() {
		var name, email, phone, loginID string
		var first, last time.Time
		var watched, reactions, questions int64
		if err := rows.Scan(&name, &email, &phone, &loginID, &first, &last, &watched, &reactions, &questions); err != nil {
			return fiber.NewError(fiber.StatusInternalServerError, "scan failed")
		}
		totalWatch += watched
		pct := 0
		if durationSecs > 0 {
			pct = int(watched * 100 / int64(durationSecs))
			if pct > 100 {
				pct = 100
			}
		}
		out = append(out, fiber.Map{
			"name": name, "email": email, "phone": phone, "login_id": loginID,
			"first_seen": first.UTC().Format(time.RFC3339), "last_seen": last.UTC().Format(time.RFC3339),
			"watched_seconds": watched, "watched_pct": pct,
			"span_seconds": int64(last.Sub(first).Seconds()), "reactions": reactions, "questions": questions,
		})
	}
	avg := int64(0)
	if len(out) > 0 {
		avg = totalWatch / int64(len(out))
	}
	return c.JSON(fiber.Map{"attendance": out, "count": len(out), "duration": durationSecs, "avg_watched_seconds": avg})
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
	// The host can always broadcast to viewers; chat_enabled only gates student
	// chat (which is otherwise mentor-only by design).
	if !chatOK && !isStaff {
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
