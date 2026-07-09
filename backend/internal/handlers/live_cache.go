package handlers

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/gofiber/fiber/v2"
)

// Hot-path in-memory caches for the live room. One API process serves every
// viewer of a session, and the state / playlist / presence / reactions that
// each viewer polls are IDENTICAL across all of them. So we compute the shared
// work ONCE per short window and hand the same result to the thousands of
// pollers, instead of hitting Postgres per request. This turns O(viewers) DB
// load into O(1) per session per window — the whole reason a modest box can
// carry a few thousand concurrent "recorded-as-live" viewers (the video bytes
// never touch us; they stream from the R2 CDN).
//
// Everything here is process-local. We run a single instance, so a session's
// viewers all land here; on restart the caches simply repopulate within one
// poll cycle. All maps are guarded by their own mutex and pruned by a janitor.

// ---- access (enrollment / staff) cache ---------------------------------------
// Whether a given user may view a given session changes rarely, so we cache it
// for ~45s. This is what lets a cache-hit state/heartbeat/react request do ZERO
// database queries.

type accessEntry struct {
	chatOK, qaOK, reactOK, isStaff, allowed bool
	exp                                     time.Time
}

var (
	accessMu    sync.Mutex
	accessCache = map[string]accessEntry{} // key: sessionID|userID
)

const accessTTL = 45 * time.Second

// liveAccessCached is the cached form of liveAccess: it authorizes the caller
// for a session and returns the chat / Q&A / reactions toggles, whether they're
// staff, and whether they're allowed at all. On a miss it runs one light query.
func (h *Handlers) liveAccessCached(c *fiber.Ctx, sessionID string) (chatOK, qaOK, reactOK, isStaff, allowed bool) {
	h.startLiveMaintenance()
	key := sessionID + "|" + callerID(c)
	now := time.Now()
	accessMu.Lock()
	if e, ok := accessCache[key]; ok && now.Before(e.exp) {
		accessMu.Unlock()
		return e.chatOK, e.qaOK, e.reactOK, e.isStaff, e.allowed
	}
	accessMu.Unlock()

	// A global staff role (admin / host) may view and host ANY session — resolve
	// that from the role ALONE, before and independent of the session row, so a
	// missing row, enrollment gap, batch mismatch, or query hiccup can never 403
	// an admin. Toggles are read best-effort and default on for staff.
	switch callerRole(c) {
	case "superadmin", "manager", "instructor", "live_host":
		chatOK, qaOK, reactOK = true, true, true
		_ = h.Pool.QueryRow(c.Context(),
			`SELECT chat_enabled, qa_enabled, reactions_enabled FROM class_sessions WHERE id=$1`, sessionID).
			Scan(&chatOK, &qaOK, &reactOK)
		accessMu.Lock()
		accessCache[key] = accessEntry{chatOK, qaOK, reactOK, true, true, now.Add(accessTTL)}
		accessMu.Unlock()
		return chatOK, qaOK, reactOK, true, true
	}

	var courseID string
	var enrolled bool
	err := h.Pool.QueryRow(c.Context(), `
		SELECT cs.chat_enabled, cs.qa_enabled, cs.reactions_enabled, cs.course_id,
		       (EXISTS(SELECT 1 FROM course_enrollments ce WHERE ce.course_id=cs.course_id AND ce.user_id=$2 AND ce.status='active')
		        AND (cs.batch_number IS NULL OR cs.batch_number = (SELECT batch FROM users WHERE id=$2)))
		FROM class_sessions cs WHERE cs.id=$1`, sessionID, callerID(c)).Scan(&chatOK, &qaOK, &reactOK, &courseID, &enrolled)
	if err != nil {
		return false, false, false, false, false // unknown session / error → not allowed (uncached)
	}
	isStaff = h.liveStaff(c, courseID) // per-course managers, etc.
	allowed = enrolled || isStaff
	accessMu.Lock()
	accessCache[key] = accessEntry{chatOK, qaOK, reactOK, isStaff, allowed, now.Add(accessTTL)}
	accessMu.Unlock()
	return
}

// invalidateLiveCaches drops the cached state, playlist body, and per-user
// access/allow entries for a session so a host control change (toggle, pause,
// black-out, end) takes effect on viewers within one poll instead of a TTL.
func invalidateLiveCaches(sessionID string) {
	stateMu.Lock()
	delete(stateCache, sessionID)
	stateMu.Unlock()
	playlistBodyMu.Lock()
	delete(playlistBody, sessionID)
	playlistBodyMu.Unlock()
	prefix := sessionID + "|"
	accessMu.Lock()
	for k := range accessCache {
		if strings.HasPrefix(k, prefix) {
			delete(accessCache, k)
		}
	}
	accessMu.Unlock()
	pallowMu.Lock()
	for k := range pallow {
		if strings.HasPrefix(k, prefix) {
			delete(pallow, k)
		}
	}
	pallowMu.Unlock()
}

// ---- session state cache -----------------------------------------------------
// The shared state block (status, viewer count, playlist URL, reaction batch)
// is the same for every viewer, so we cache it per session for a couple of
// seconds. The per-user is_host flag is added by the handler after the fact.

type stateEntry struct {
	data fiber.Map
	exp  time.Time
}

var (
	stateMu    sync.Mutex
	stateCache = map[string]stateEntry{}
)

const stateTTL = 2 * time.Second

// ---- live playlist body cache ------------------------------------------------
// The sliding-window playlist depends only on (session, wall-clock), not on the
// viewer. It advances one segment every ~6s, so a ~1.5s cache is always safe and
// collapses hls.js's per-viewer refresh into one build per session per window.

type playlistEntry struct {
	body string
	exp  time.Time
}

var (
	playlistBodyMu sync.Mutex
	playlistBody   = map[string]playlistEntry{}
)

const playlistBodyTTL = 1500 * time.Millisecond

// playlistAllowed is the cached enrollment/role gate for the token-auth playlist
// and key routes (which don't carry a role in locals, so it's checked in SQL).
type pallowEntry struct {
	allowed bool
	exp     time.Time
}

var (
	pallowMu sync.Mutex
	pallow   = map[string]pallowEntry{}
)

func (h *Handlers) playlistAllowed(c *fiber.Ctx, sessionID string) bool {
	h.startLiveMaintenance()
	key := sessionID + "|" + callerID(c)
	now := time.Now()
	pallowMu.Lock()
	if e, ok := pallow[key]; ok && now.Before(e.exp) {
		pallowMu.Unlock()
		return e.allowed
	}
	pallowMu.Unlock()

	var allowed bool
	err := h.Pool.QueryRow(c.Context(), `
		SELECT (EXISTS(SELECT 1 FROM course_enrollments ce JOIN class_sessions cs ON cs.course_id=ce.course_id
		               WHERE cs.id=$1 AND ce.user_id=$2 AND ce.status='active'
		                 AND (cs.batch_number IS NULL OR cs.batch_number = (SELECT batch FROM users WHERE id=$2)))
		        OR (SELECT role FROM users WHERE id=$2) IN ('manager','superadmin','instructor','live_host'))`,
		sessionID, callerID(c)).Scan(&allowed)
	if err != nil {
		return false
	}
	pallowMu.Lock()
	pallow[key] = pallowEntry{allowed, now.Add(accessTTL)}
	pallowMu.Unlock()
	return allowed
}

// ---- in-memory presence + attendance -----------------------------------------
// Heartbeats update a map instead of writing a row per viewer per interval, so
// the live headcount is read straight from memory (no presence DB traffic on the
// hot path). Each viewer's watched time is also accumulated here and flushed to
// live_attendance in batches (flushAttendance), giving durable attendance for
// export without per-heartbeat writes. A gap between heartbeats longer than
// maxBeatGap (tab closed, then reopened) is NOT counted as watched.

const maxBeatGap = 40 // s — cap the credit per heartbeat so away-time isn't counted

type viewerRec struct {
	firstSeen int64 // unix sec, set once
	lastSeen  int64 // unix sec, last heartbeat
	watched   int64 // seconds accumulated since the last flush
	reactions int64 // reactions sent since the last flush
	dirty     bool  // has unflushed change
	left      bool  // emitted a "left" event (reset on rejoin) — feed de-dupe
}

var (
	presenceMu sync.Mutex
	presence   = map[string]map[string]*viewerRec{} // session -> user -> record
)

// ---- live join/leave feed ----------------------------------------------------
// A small ring of join/leave events per session drives the host's live feed.
// Joins are recorded when a viewer first heartbeats (or returns after a gap);
// leaves are swept when a viewer stops heartbeating (goneAfter). All guarded by
// presenceMu (recorded alongside presence updates).

const goneAfter = 35 // s without a heartbeat → considered to have left

type liveEvent struct {
	user string
	join bool
	ts   int64
}

var liveEvents = map[string][]liveEvent{} // session -> recent events (bounded)

// addLiveEvent appends an event; caller must hold presenceMu.
func addLiveEvent(session, user string, join bool) {
	ev := append(liveEvents[session], liveEvent{user: user, join: join, ts: time.Now().Unix()})
	if len(ev) > 120 {
		ev = ev[len(ev)-120:]
	}
	liveEvents[session] = ev
}

// sweepLeaves marks viewers who stopped heartbeating as "left" and records the
// event once. Called when the host fetches the feed so leaves show promptly.
func sweepLeaves(session string) {
	now := time.Now().Unix()
	presenceMu.Lock()
	if m := presence[session]; m != nil {
		for u, r := range m {
			if !r.left && now-r.lastSeen > goneAfter {
				r.left = true
				addLiveEvent(session, u, false)
			}
		}
	}
	presenceMu.Unlock()
}

// liveFeed returns a copy of the session's recent join/leave events.
func liveFeed(session string) []liveEvent {
	presenceMu.Lock()
	defer presenceMu.Unlock()
	ev := liveEvents[session]
	out := make([]liveEvent, len(ev))
	copy(out, ev)
	return out
}

func touchPresence(session, user string) {
	now := time.Now().Unix()
	presenceMu.Lock()
	m := presence[session]
	if m == nil {
		m = map[string]*viewerRec{}
		presence[session] = m
	}
	if r := m[user]; r == nil {
		m[user] = &viewerRec{firstSeen: now, lastSeen: now, dirty: true}
		addLiveEvent(session, user, true) // joined
	} else {
		if d := now - r.lastSeen; d > 0 && d <= maxBeatGap {
			r.watched += d
		}
		if r.left { // returned after being marked gone
			r.left = false
			addLiveEvent(session, user, true)
		}
		r.lastSeen = now
		r.dirty = true
	}
	presenceMu.Unlock()
}

// bumpReaction records that a user sent a reaction (for attendance engagement).
func bumpReaction(session, user string) {
	now := time.Now().Unix()
	presenceMu.Lock()
	m := presence[session]
	if m == nil {
		m = map[string]*viewerRec{}
		presence[session] = m
	}
	r := m[user]
	if r == nil {
		r = &viewerRec{firstSeen: now, lastSeen: now}
		m[user] = r
	}
	r.reactions++
	r.lastSeen = now
	r.dirty = true
	presenceMu.Unlock()
}

// presenceCount returns the number of users seen within `within`.
func presenceCount(session string, within time.Duration) int {
	cutoff := time.Now().Unix() - int64(within.Seconds())
	presenceMu.Lock()
	defer presenceMu.Unlock()
	m := presence[session]
	if m == nil {
		return 0
	}
	n := 0
	for _, r := range m {
		if r.lastSeen >= cutoff {
			n++
		}
	}
	return n
}

// presenceUsers returns the user ids seen within `within` (for the host's live
// listeners list). Capped so a huge room can't blow up the response.
func presenceUsers(session string, within time.Duration) []string {
	cutoff := time.Now().Unix() - int64(within.Seconds())
	presenceMu.Lock()
	defer presenceMu.Unlock()
	m := presence[session]
	if m == nil {
		return nil
	}
	out := make([]string, 0, len(m))
	for u, r := range m {
		if r.lastSeen >= cutoff {
			out = append(out, u)
			if len(out) >= 500 {
				break
			}
		}
	}
	return out
}

// flushAttendance writes accumulated watch-time deltas to live_attendance and
// prunes viewers idle for >5min. Called periodically and before an export so the
// numbers are current. If onlySession is non-empty only that session is flushed.
func (h *Handlers) flushAttendance(onlySession string) {
	type row struct {
		session, user                  string
		first, last, watchedSecs, react int64
	}
	var rows []row
	now := time.Now().Unix()
	presenceMu.Lock()
	for s, m := range presence {
		if onlySession != "" && s != onlySession {
			continue
		}
		for u, r := range m {
			if r.dirty {
				rows = append(rows, row{s, u, r.firstSeen, r.lastSeen, r.watched, r.reactions})
				r.watched = 0
				r.reactions = 0
				r.dirty = false
			}
			if now-r.lastSeen > 300 { // idle → prune (already flushed above)
				delete(m, u)
			}
		}
		if len(m) == 0 {
			delete(presence, s)
			delete(liveEvents, s)
		}
	}
	presenceMu.Unlock()

	for _, rw := range rows {
		_, _ = h.Pool.Exec(context.Background(), `
			INSERT INTO live_attendance (session_id, user_id, first_seen, last_seen, watched_seconds, reactions_sent)
			VALUES ($1, $2, to_timestamp($3), to_timestamp($4), $5, $6)
			ON CONFLICT (session_id, user_id) DO UPDATE SET
				first_seen      = LEAST(live_attendance.first_seen, EXCLUDED.first_seen),
				last_seen       = GREATEST(live_attendance.last_seen, EXCLUDED.last_seen),
				watched_seconds = live_attendance.watched_seconds + EXCLUDED.watched_seconds,
				reactions_sent  = live_attendance.reactions_sent  + EXCLUDED.reactions_sent`,
			rw.session, rw.user, rw.first, rw.last, rw.watchedSecs, rw.react)
	}
}

// ---- live reactions ----------------------------------------------------------
// Tapping a reaction increments an in-memory tally (no DB). The tallies since
// the last state rebuild ride along on the /state response everyone already
// polls — so reactions broadcast to the whole room with ZERO extra requests and
// ZERO new polling. seq lets a client float each batch at most once.

var liveReactionSet = map[string]struct{}{
	"👍": {}, "👏": {}, "❤️": {}, "😂": {}, "😮": {}, "🎉": {}, "🚀": {}, "👌": {},
}

type reactionBucket struct {
	counts map[string]int
	seq    int
}

var (
	reactMu    sync.Mutex
	reactAccum = map[string]*reactionBucket{}
)

// addReaction records one reaction; returns false for an unknown emoji.
func addReaction(session, emoji string) bool {
	if _, ok := liveReactionSet[emoji]; !ok {
		return false
	}
	reactMu.Lock()
	b := reactAccum[session]
	if b == nil {
		b = &reactionBucket{counts: map[string]int{}}
		reactAccum[session] = b
	}
	if b.counts[emoji] < 1000 { // soft cap so a spammer can't blow the number up
		b.counts[emoji]++
	}
	reactMu.Unlock()
	return true
}

// snapshotReactions returns and RESETS the pending reaction tallies. Called once
// per state-cache rebuild (~every 2s); seq increments only when there was
// something, so an idle session keeps the same seq and clients don't re-float.
// Per-emoji count is capped so the client's burst is bounded.
func snapshotReactions(session string) (map[string]int, int) {
	reactMu.Lock()
	defer reactMu.Unlock()
	b := reactAccum[session]
	if b == nil {
		return nil, 0
	}
	if len(b.counts) == 0 {
		return nil, b.seq
	}
	out := make(map[string]int, len(b.counts))
	for k, v := range b.counts {
		if v > 50 {
			v = 50
		}
		out[k] = v
	}
	b.counts = map[string]int{}
	b.seq++
	if b.seq > 1<<30 {
		b.seq = 1
	}
	return out, b.seq
}

// ---- maintenance -------------------------------------------------------------
// A single background loop (started on first live request) that flushes
// attendance and prunes expired TTL entries so idle sessions don't leak memory.

var liveMaintOnce sync.Once

func (h *Handlers) startLiveMaintenance() {
	liveMaintOnce.Do(func() {
		go func() {
			t := time.NewTicker(45 * time.Second)
			defer t.Stop()
			for range t.C {
				h.flushAttendance("") // persist watch-time deltas, prune idle viewers
				now := time.Now()
				accessMu.Lock()
				for k, e := range accessCache {
					if now.After(e.exp) {
						delete(accessCache, k)
					}
				}
				accessMu.Unlock()
				pallowMu.Lock()
				for k, e := range pallow {
					if now.After(e.exp) {
						delete(pallow, k)
					}
				}
				pallowMu.Unlock()
				stateMu.Lock()
				for k, e := range stateCache {
					if now.After(e.exp) {
						delete(stateCache, k)
					}
				}
				stateMu.Unlock()
				playlistBodyMu.Lock()
				for k, e := range playlistBody {
					if now.After(e.exp) {
						delete(playlistBody, k)
					}
				}
				playlistBodyMu.Unlock()
				reactMu.Lock()
				for k, b := range reactAccum {
					if len(b.counts) == 0 {
						delete(reactAccum, k)
					}
				}
				reactMu.Unlock()
			}
		}()
	})
}

// normalizeReaction trims and validates an incoming reaction emoji.
func normalizeReaction(s string) (string, bool) {
	s = strings.TrimSpace(s)
	_, ok := liveReactionSet[s]
	return s, ok
}
