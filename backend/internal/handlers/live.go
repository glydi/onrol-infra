package handlers

import (
	"errors"

	"github.com/gofiber/fiber/v2"
	"github.com/jackc/pgx/v5"

	"github.com/onrol/lms-backend/internal/middleware"
	"github.com/onrol/lms-backend/internal/zoho"
)

// LiveJoin returns what the Flutter WebView should load to put the authenticated
// student into a Zoho webinar. See ARCHITECTURE.md §4.3.
//
// Strategy:
//  1. Always compute the embed registration URL (reliable: Zoho's own widget).
//  2. Best-effort: POST the web-registration form server-side with the student's
//     ACCOUNT identity. If Zoho hands back a join URL synchronously, return it so
//     the app can skip the registration step. (Most plans email it instead — the
//     embed URL is then the answer.)
//
// Per-student forensic identity does NOT depend on Zoho here: the Flutter
// watermark overlay is keyed to the JWT account, not to what the user types in
// Zoho's form.
func (h *Handlers) LiveJoin(c *fiber.Ctx) error {
	if h.Zoho == nil {
		return fiber.NewError(fiber.StatusServiceUnavailable, "live integration not configured")
	}
	userID := c.Locals(middleware.LocalUserID).(string)
	webinarID := c.Params("webinar_id")

	// Load the webinar config.
	var (
		title, embedSessionID                           string
		webformURL, webformSysID, webformDigest, encTok string
		returnURL                                       string
	)
	err := h.Pool.QueryRow(c.Context(),
		`SELECT title, COALESCE(embed_session_id,''), COALESCE(webform_url,''),
		        COALESCE(webform_sys_id,''), COALESCE(webform_digest,''),
		        COALESCE(webform_enc,''), COALESCE(return_url,'')
		   FROM webinars WHERE id=$1 AND is_active`,
		webinarID,
	).Scan(&title, &embedSessionID, &webformURL, &webformSysID, &webformDigest, &encTok, &returnURL)
	if errors.Is(err, pgx.ErrNoRows) {
		return fiber.NewError(fiber.StatusNotFound, "webinar not found")
	}
	if err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "webinar lookup failed")
	}

	// Student identity from the account (not user-supplied).
	var email, fullName string
	if err := h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(email,''), full_name FROM users WHERE id=$1`, userID,
	).Scan(&email, &fullName); err != nil {
		return fiber.NewError(fiber.StatusInternalServerError, "user lookup failed")
	}

	// Return a previously captured direct join URL if we have one.
	var cachedJoin string
	_ = h.Pool.QueryRow(c.Context(),
		`SELECT COALESCE(join_url,'') FROM webinar_registrations
		  WHERE user_id=$1 AND webinar_key=$2`, userID, webinarID,
	).Scan(&cachedJoin)
	if cachedJoin != "" {
		return c.JSON(fiber.Map{"mode": "join", "url": cachedJoin, "cached": true, "title": title})
	}

	embedURL := h.Zoho.EmbedURL(embedSessionID, email)

	// Best-effort server-side registration to bind identity / maybe get a link.
	var joinURL, registrantNote string
	if webformSysID != "" {
		res, ferr := h.Zoho.RegisterViaWebForm(c.Context(), zoho.WebForm{
			URL: webformURL, SysID: webformSysID, Digest: webformDigest,
			Enc: encTok, ReturnURL: returnURL,
		}, fullName, email, "Asia/Kolkata")
		switch {
		case ferr != nil:
			registrantNote = "webform registration not attempted/failed: " + ferr.Error()
		case res.JoinURL != "":
			joinURL = res.JoinURL
		default:
			registrantNote = "registered via webform; Zoho likely emailed the join link"
		}
	}

	if joinURL != "" {
		_, _ = h.Pool.Exec(c.Context(),
			`INSERT INTO webinar_registrations (user_id, webinar_key, join_url)
			 VALUES ($1,$2,$3)
			 ON CONFLICT (user_id, webinar_key) DO UPDATE SET join_url=EXCLUDED.join_url`,
			userID, webinarID, joinURL)
		return c.JSON(fiber.Map{"mode": "join", "url": joinURL, "cached": false, "title": title})
	}

	// Fall back to the reliable embed-registration widget.
	return c.JSON(fiber.Map{
		"mode":  "embed",
		"url":   embedURL,
		"title": title,
		"note":  registrantNote,
	})
}
