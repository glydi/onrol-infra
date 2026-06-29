package handlers

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5"
)

// Simulated-live streaming. A class session backed by a recorded asset
// (media_asset_id set) is served as a sliding-window HLS "live" stream: the
// playlist only ever names the segments up to (now - starts_at), so the player
// can't seek past the live edge, a hard pause just falls behind and snaps back,
// and a reload re-derives the exact wall-clock position. The segments themselves
// are byte-identical to the VOD ones and still come straight from the R2 CDN —
// we only choose which subset of them the per-request playlist exposes.
//
// IV continuity: ffmpeg encrypted each segment with the implicit AES-128 IV =
// its media-sequence number (its absolute index). So the windowed playlist MUST
// set #EXT-X-MEDIA-SEQUENCE to the absolute index of its first segment, and we
// reproduce the original #EXT-X-KEY line verbatim (only swapping the key URI to
// the live, enrollment-gated key endpoint). Renumbering from 0 would decrypt
// with the wrong IV and produce garbage.

// How many trailing segments the live window exposes (~6s each → ~6 min of DVR).
// This must comfortably exceed how far the player sits behind the live edge
// (hls.js liveSyncDuration ≈ 18s) plus its back-buffer, or a rebuffer can push
// the playhead off the back of the window and stall permanently. 60 is huge
// headroom while keeping the playlist small.
const liveWindowSegments = 60

type liveSeg struct {
	name string
	dur  float64
}

// parsedPlaylist is the immutable, cached parse of an asset's VOD index.m3u8.
type parsedPlaylist struct {
	segs      []liveSeg
	total     float64 // sum of segment durations (seconds)
	targetDur int
	keyLine   string // original #EXT-X-KEY line (URI rewritten per session)
	base      string // segment base URL, e.g. https://cdn/videos/<asset>/hls/
}

var (
	livePlaylistMu    sync.RWMutex
	livePlaylistCache = map[string]*parsedPlaylist{}
	liveHTTP          = &http.Client{Timeout: 15 * time.Second}
)

// loadLivePlaylist fetches and parses an asset's VOD index.m3u8 once, then caches
// it (the HLS output is immutable once the asset is ready).
func (h *Handlers) loadLivePlaylist(ctx context.Context, assetID, hlsURL string) (*parsedPlaylist, error) {
	livePlaylistMu.RLock()
	pp := livePlaylistCache[assetID]
	livePlaylistMu.RUnlock()
	if pp != nil {
		return pp, nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, hlsURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := liveHTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("index.m3u8 status %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	pp = parseM3U8(string(body), strings.TrimSuffix(hlsURL, "index.m3u8"))
	if len(pp.segs) == 0 {
		return nil, errors.New("playlist has no segments")
	}
	livePlaylistMu.Lock()
	livePlaylistCache[assetID] = pp
	livePlaylistMu.Unlock()
	return pp, nil
}

func parseM3U8(text, base string) *parsedPlaylist {
	pp := &parsedPlaylist{targetDur: 6, base: base}
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 0, 64*1024), 1<<20)
	var pendingDur float64
	var havePending bool
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		switch {
		case line == "":
			continue
		case strings.HasPrefix(line, "#EXT-X-KEY:"):
			pp.keyLine = line
		case strings.HasPrefix(line, "#EXT-X-TARGETDURATION:"):
			if v, err := strconv.Atoi(strings.TrimSpace(strings.TrimPrefix(line, "#EXT-X-TARGETDURATION:"))); err == nil {
				pp.targetDur = v
			}
		case strings.HasPrefix(line, "#EXTINF:"):
			v := strings.TrimPrefix(line, "#EXTINF:")
			if i := strings.IndexByte(v, ','); i >= 0 {
				v = v[:i]
			}
			if d, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil {
				pendingDur, havePending = d, true
			}
		case strings.HasPrefix(line, "#"):
			// other tags (VERSION, MEDIA-SEQUENCE, PLAYLIST-TYPE, ENDLIST…) ignored
		default:
			if havePending {
				pp.segs = append(pp.segs, liveSeg{name: line, dur: pendingDur})
				pp.total += pendingDur
				havePending = false
			}
		}
	}
	return pp
}

// rewriteKeyURI returns the original #EXT-X-KEY line with only its URI="…"
// swapped for newURI (preserving METHOD and any IV so decryption stays correct).
func rewriteKeyURI(keyLine, newURI string) string {
	const marker = `URI="`
	i := strings.Index(keyLine, marker)
	if i < 0 {
		return keyLine
	}
	start := i + len(marker)
	end := strings.IndexByte(keyLine[start:], '"')
	if end < 0 {
		return keyLine
	}
	return keyLine[:start] + newURI + keyLine[start+end:]
}

// LivePlaylist serves the time-windowed HLS playlist for a simulated-live
// session. Token-auth (hls.js can't attach the device header) + enrollment.
func (h *Handlers) LivePlaylist(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	var assetID, hlsURL string
	var startsAt time.Time
	var durDB int
	err := h.Pool.QueryRow(c.Context(), `
		SELECT cs.media_asset_id, cs.starts_at, COALESCE(ma.hls_url,''), ma.duration_seconds
		FROM class_sessions cs
		JOIN media_assets ma ON ma.id = cs.media_asset_id
		JOIN course_enrollments ce ON ce.course_id = cs.course_id AND ce.user_id = $2 AND ce.status = 'active'
		WHERE cs.id = $1`, sessionID, callerID(c)).Scan(&assetID, &startsAt, &hlsURL, &durDB)
	if errors.Is(err, pgx.ErrNoRows) {
		return fiber.NewError(fiber.StatusForbidden, "not entitled to this session")
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "session load failed")
	}
	if hlsURL == "" {
		return fiber.NewError(fiber.StatusConflict, "recording not ready")
	}

	pp, err := h.loadLivePlaylist(c.Context(), assetID, hlsURL)
	if err != nil {
		return fiber.NewError(fiber.StatusBadGateway, "playlist unavailable")
	}
	// Lazy backfill of duration for assets transcoded before we recorded it.
	if durDB == 0 && pp.total > 0 {
		_, _ = h.Pool.Exec(c.Context(), `UPDATE media_assets SET duration_seconds=$2 WHERE id=$1`, assetID, int(pp.total+0.5))
	}

	elapsed := time.Since(startsAt).Seconds()
	if elapsed <= 0 {
		// Before the scheduled start there is nothing to play; the client shows
		// the lobby/countdown and only requests this once /state reports "live".
		return fiber.NewError(fiber.StatusTooEarly, "session has not started")
	}

	// Live edge = last segment whose start time is at or before elapsed.
	liveEdge := 0
	start := 0.0
	for i := range pp.segs {
		if start <= elapsed {
			liveEdge = i
		} else {
			break
		}
		start += pp.segs[i].dur
	}
	ended := elapsed >= pp.total

	windowStart := liveEdge - (liveWindowSegments - 1)
	if windowStart < 0 {
		windowStart = 0
	}

	keyURI := h.Cfg.AppBaseURL + "/api/v1/me/live/" + sessionID + "/hls.key"
	var sb strings.Builder
	sb.WriteString("#EXTM3U\n#EXT-X-VERSION:3\n")
	fmt.Fprintf(&sb, "#EXT-X-TARGETDURATION:%d\n", pp.targetDur)
	fmt.Fprintf(&sb, "#EXT-X-MEDIA-SEQUENCE:%d\n", windowStart)
	if pp.keyLine != "" {
		sb.WriteString(rewriteKeyURI(pp.keyLine, keyURI))
		sb.WriteByte('\n')
	}
	for i := windowStart; i <= liveEdge && i < len(pp.segs); i++ {
		fmt.Fprintf(&sb, "#EXTINF:%.6f,\n%s%s\n", pp.segs[i].dur, pp.base, pp.segs[i].name)
	}
	if ended {
		sb.WriteString("#EXT-X-ENDLIST\n")
	}

	c.Set(fiber.HeaderContentType, "application/vnd.apple.mpegurl")
	c.Set(fiber.HeaderCacheControl, "no-store")
	return c.SendString(sb.String())
}

// LiveHLSKey serves the AES-128 key for a simulated-live session's recording,
// gated by enrollment in the session's course (token-auth, like the VOD key).
func (h *Handlers) LiveHLSKey(c *fiber.Ctx) error {
	sessionID := c.Params("id")
	var key []byte
	err := h.Pool.QueryRow(c.Context(), `
		SELECT ma.enc_key
		FROM class_sessions cs
		JOIN media_assets ma ON ma.id = cs.media_asset_id
		JOIN course_enrollments ce ON ce.course_id = cs.course_id AND ce.user_id = $2 AND ce.status = 'active'
		WHERE cs.id = $1`, sessionID, callerID(c)).Scan(&key)
	if err != nil || len(key) == 0 {
		return fiber.NewError(fiber.StatusForbidden, "not entitled")
	}
	c.Set(fiber.HeaderContentType, "application/octet-stream")
	c.Set(fiber.HeaderCacheControl, "no-store")
	return c.Send(key)
}
