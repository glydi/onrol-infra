// Package zoho integrates Zoho Webinar using the two mechanisms Zoho actually
// exposes for self-serve plans:
//
//  1. An embeddable registration widget (RELIABLE):
//     https://<base>/meeting/register/embed?sessionId=<id>
//     -> render this in the Flutter WebView; the student registers + joins
//     inside Zoho's own UI.
//
//  2. A web-to-registration form POST (BEST-EFFORT):
//     POST https://<base>/meeting/WebForm with the hidden form tokens.
//     Zoho typically EMAILS the unique join link rather than returning it, so
//     treat any synchronously-returned join URL as a bonus, not a guarantee.
//     cmd/zoho-spike proves which behaviour your account exhibits.
//
// There is also a full OAuth REST API on higher Zoho Meeting tiers; if you gain
// access to it, add it here as a third path. We don't ship speculative code for
// it because the artifacts on hand are the embed + web form.
package zoho

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"
)

// actionType is base64("Registrations") — the literal value Zoho's form uses.
const actionTypeRegistrations = "UmVnaXN0cmF0aW9ucw=="

type Config struct {
	WebinarBase string // e.g. https://webinar.zoho.in (embed / web-form base)

	// OAuth REST API v2 (real registration path). When all four are set the
	// client registers attendees via the API and returns a private join link.
	APIBase      string // e.g. https://meeting.zoho.in/api/v2
	AccountsBase string // e.g. https://accounts.zoho.in
	OrgID        string // numeric org id (zsoid) in the API path
	ClientID     string
	ClientSecret string
	RefreshToken string
}

type Client struct {
	cfg  Config
	http *http.Client

	// Cached OAuth access token (refreshed from RefreshToken on demand).
	tokMu  sync.Mutex
	tok    string
	tokExp time.Time
}

func New(cfg Config) *Client {
	if cfg.WebinarBase == "" {
		cfg.WebinarBase = "https://webinar.zoho.in"
	}
	if cfg.APIBase == "" {
		cfg.APIBase = "https://meeting.zoho.in/api/v2"
	}
	if cfg.AccountsBase == "" {
		cfg.AccountsBase = "https://accounts.zoho.in"
	}
	return &Client{
		cfg: cfg,
		http: &http.Client{
			Timeout: 15 * time.Second,
			// Don't auto-follow redirects: we want to read the Location header
			// to learn where Zoho sends the registrant (and spot a join URL).
			CheckRedirect: func(*http.Request, []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}

// APIEnabled reports whether the OAuth REST API path is configured.
func (c *Client) APIEnabled() bool {
	return c.cfg.OrgID != "" && c.cfg.ClientID != "" &&
		c.cfg.ClientSecret != "" && c.cfg.RefreshToken != ""
}

// EmbedURL builds the registration-widget URL for the Flutter WebView. The
// email prefill is best-effort — Zoho may or may not honour it.
func (c *Client) EmbedURL(sessionID, email string) string {
	u := fmt.Sprintf("%s/meeting/register/embed?sessionId=%s",
		strings.TrimRight(c.cfg.WebinarBase, "/"), url.QueryEscape(sessionID))
	if email != "" {
		u += "&email=" + url.QueryEscape(email)
	}
	return u
}

// WebForm holds the hidden tokens copied from a webinar's embed registration
// form. These are public (they ship in client-side HTML) but are per-webinar,
// so we store them in the webinars table, not in source.
type WebForm struct {
	URL       string // https://webinar.zoho.in/meeting/WebForm
	SysID     string // hidden "sysId"
	Digest    string // hidden "xnQsjsdp"
	Enc       string // hidden "xmIwtLD"
	ReturnURL string // hidden "returnURL"
}

func (w WebForm) usable() bool {
	return w.URL != "" && w.SysID != "" && w.Digest != "" && w.Enc != ""
}

// WebFormResult captures everything useful from the registration POST so the
// caller (and the spike) can see exactly what Zoho did.
type WebFormResult struct {
	StatusCode int    `json:"status_code"`
	Location   string `json:"location"`  // redirect target, if any
	JoinURL    string `json:"join_url"`  // best-effort extraction; often empty
	BodySnip   string `json:"body_snip"` // first ~2KB of the response body
}

var joinURLRe = regexp.MustCompile(`https?://[^\s"'<>]*?(?:join|startmeeting|present)[^\s"'<>]*`)

// RegisterViaWebForm submits the registration form server-side on behalf of an
// authenticated student. Returns the raw result; a populated JoinURL is a bonus.
func (c *Client) RegisterViaWebForm(ctx context.Context, form WebForm, fullName, email, timezone string) (*WebFormResult, error) {
	if !form.usable() {
		return nil, fmt.Errorf("webform not configured for this webinar")
	}
	if timezone == "" {
		timezone = "Asia/Kolkata"
	}
	first, last := splitName(fullName)

	values := url.Values{}
	values.Set("xnQsjsdp", form.Digest)
	values.Set("xmIwtLD", form.Enc)
	values.Set("zc_gad", "")
	values.Set("actionType", actionTypeRegistrations)
	values.Set("returnURL", form.ReturnURL)
	values.Set("sysId", form.SysID)
	values.Set("isEmbedForm", "true")
	values.Set("timezone", timezone)
	values.Set("NAME", first)           // First Name
	values.Set("REGISTRATIONCF1", last) // Last Name
	values.Set("EMAIL", email)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, form.URL,
		strings.NewReader(values.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "text/html,application/xhtml+xml")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("webform POST: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
	location := resp.Header.Get("Location")

	join := ""
	if m := joinURLRe.FindString(location); m != "" {
		join = m
	} else if m := joinURLRe.FindString(string(body)); m != "" {
		join = m
	}

	snip := string(body)
	if len(snip) > 2048 {
		snip = snip[:2048]
	}
	return &WebFormResult{
		StatusCode: resp.StatusCode,
		Location:   location,
		JoinURL:    join,
		BodySnip:   snip,
	}, nil
}

// accessToken returns a valid OAuth access token, refreshing it from the
// long-lived refresh token when the cached one is missing or near expiry.
func (c *Client) accessToken(ctx context.Context) (string, error) {
	c.tokMu.Lock()
	defer c.tokMu.Unlock()
	if c.tok != "" && time.Now().Before(c.tokExp) {
		return c.tok, nil
	}

	form := url.Values{}
	form.Set("grant_type", "refresh_token")
	form.Set("client_id", c.cfg.ClientID)
	form.Set("client_secret", c.cfg.ClientSecret)
	form.Set("refresh_token", c.cfg.RefreshToken)

	endpoint := strings.TrimRight(c.cfg.AccountsBase, "/") + "/oauth/v2/token"
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint,
		strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("zoho token refresh: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))

	var tr struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
	}
	if err := json.Unmarshal(body, &tr); err != nil {
		return "", fmt.Errorf("zoho token refresh: bad response: %s", strings.TrimSpace(string(body)))
	}
	if tr.AccessToken == "" {
		return "", fmt.Errorf("zoho token refresh failed: %s", tr.Error)
	}

	c.tok = tr.AccessToken
	// Refresh a minute early to avoid using a token that expires mid-request.
	ttl := time.Duration(tr.ExpiresIn) * time.Second
	if ttl <= 0 {
		ttl = time.Hour
	}
	c.tokExp = time.Now().Add(ttl - time.Minute)
	return c.tok, nil
}

// CreatedWebinar is what Zoho returns after provisioning a webinar.
type CreatedWebinar struct {
	MeetingKey string // == the sessionId used by the embed/register/join URLs
	InstanceID string // the webinar "sysId" (needed by RegisterAttendee)
	RegURL     string // public registration URL (embed)
	StartLink  string // host/start link the instructor uses to run + record
}

// CreateWebinar provisions a brand-new webinar in Zoho. presenterZUID is
// required by Zoho and must be a valid Zoho user id. startTime is formatted in
// the given timezone; duration is the webinar length.
//
//	POST {APIBase}/{orgID}/webinar.json
//
// Newly-created webinars have registrationRequired=true, so RegisterAttendee
// works against them immediately.
func (c *Client) CreateWebinar(ctx context.Context, topic, agenda, presenterZUID string, startTime time.Time, duration time.Duration, timezone string) (*CreatedWebinar, error) {
	if !c.APIEnabled() {
		return nil, fmt.Errorf("zoho api not configured")
	}
	if presenterZUID == "" {
		return nil, fmt.Errorf("zoho presenter zuid not configured (set ZOHO_PRESENTER_ZUID)")
	}
	if timezone == "" {
		timezone = "Asia/Kolkata"
	}
	token, err := c.accessToken(ctx)
	if err != nil {
		return nil, err
	}

	// Zoho wants "Jul 20, 2026 04:00 PM" in the webinar's timezone.
	if loc, lerr := time.LoadLocation(timezone); lerr == nil {
		startTime = startTime.In(loc)
	}
	startStr := startTime.Format("Jan 02, 2006 03:04 PM")

	session := map[string]any{
		"topic":     topic,
		"presenter": presenterZUID,
		"startTime": startStr,
		"duration":  duration.Milliseconds(),
		"timezone":  timezone,
	}
	if agenda != "" {
		session["agenda"] = agenda
	}
	payload, _ := json.Marshal(map[string]any{"session": session})

	endpoint := fmt.Sprintf("%s/%s/webinar.json",
		strings.TrimRight(c.cfg.APIBase, "/"), url.PathEscape(c.cfg.OrgID))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(string(payload)))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Zoho-oauthtoken "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("zoho create webinar: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))

	// instanceId comes back as an array; sys_id as a string. Accept either.
	var out struct {
		Session struct {
			MeetingKey any      `json:"meetingKey"`
			SysID      string   `json:"sys_id"`
			InstanceID []string `json:"instanceId"`
			RegURL     string   `json:"registrationLink"`
			RegEmbed   string   `json:"regEmbedURL"`
			StartLink  string   `json:"startLink"`
		} `json:"session"`
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("zoho create webinar: bad response (%d): %s", resp.StatusCode, snippet(body))
	}
	meetingKey := fmt.Sprintf("%v", out.Session.MeetingKey)
	if out.Error.Message != "" || meetingKey == "" || meetingKey == "<nil>" {
		return nil, fmt.Errorf("%s", firstNonEmpty(out.Error.Message, snippet(body)))
	}
	instanceID := out.Session.SysID
	if instanceID == "" && len(out.Session.InstanceID) > 0 {
		instanceID = out.Session.InstanceID[0]
	}
	return &CreatedWebinar{
		MeetingKey: meetingKey,
		InstanceID: instanceID,
		RegURL:     firstNonEmpty(out.Session.RegEmbed, out.Session.RegURL),
		StartLink:  out.Session.StartLink,
	}, nil
}

// RegisterAttendee registers a single student for a webinar via the REST API v2
// bulk-registration endpoint and returns their private join link.
//
//	POST {APIBase}/{orgID}/register/{meetingKey}.json?sendMail=false&instanceId=<sysId>
//
// meetingKey is the webinar's session id (Zoho's regEmbedURL sessionId ==
// meetingKey); instanceID is the webinar's "sysId". Both are per-webinar.
func (c *Client) RegisterAttendee(ctx context.Context, meetingKey, instanceID, fullName, email string) (string, error) {
	if !c.APIEnabled() {
		return "", fmt.Errorf("zoho api not configured")
	}
	if meetingKey == "" || instanceID == "" {
		return "", fmt.Errorf("webinar missing meetingKey/instanceId")
	}
	token, err := c.accessToken(ctx)
	if err != nil {
		return "", err
	}
	first, last := splitName(fullName)

	payload, _ := json.Marshal(map[string]any{
		"registrant": []map[string]string{
			{"email": email, "firstName": first, "lastName": last},
		},
	})

	endpoint := fmt.Sprintf("%s/%s/register/%s.json?sendMail=false&instanceId=%s",
		strings.TrimRight(c.cfg.APIBase, "/"),
		url.PathEscape(c.cfg.OrgID), url.PathEscape(meetingKey),
		url.QueryEscape(instanceID))

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint,
		strings.NewReader(string(payload)))
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Zoho-oauthtoken "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		return "", fmt.Errorf("zoho register: %w", err)
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))

	// Success: {"registrant":[{"joinLink":"...","email":"..."}], "successCount":1,...}
	// Failure: {"errorCode":"WEBINAR_ENDED","status":"FAILED",...} or {"error":{...}}.
	var out struct {
		Registrant []struct {
			JoinLink string `json:"joinLink"`
			Email    string `json:"email"`
		} `json:"registrant"`
		SuccessCount int    `json:"successCount"`
		Status       string `json:"status"`
		ErrorCode    string `json:"errorCode"`
		Message      string `json:"message"`
		Error        struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return "", fmt.Errorf("zoho register: bad response (%d): %s", resp.StatusCode, snippet(body))
	}
	if len(out.Registrant) > 0 && out.Registrant[0].JoinLink != "" {
		return out.Registrant[0].JoinLink, nil
	}

	msg := firstNonEmpty(out.Message, out.Error.Message, out.ErrorCode, out.Status)
	if msg == "" {
		msg = snippet(body)
	}
	return "", fmt.Errorf("zoho register: no join link (%d): %s", resp.StatusCode, msg)
}

// ParticipantURL skips Zoho's redundant "You're all set" launcher page for a
// registered attendee. Zoho's own WebinarJoin client turns the private
// /meeting/register/join link into this participant URL when "Join Now" is
// pressed. Doing the same transformation here is especially important on web,
// where browser same-origin rules prevent ONROL from pressing a button inside
// Zoho's iframe.
//
// Unknown URL shapes are returned unchanged so a future Zoho link format keeps
// using the safe launcher instead of producing a broken participant URL.
func ParticipantURL(joinLink string) string {
	u, err := url.Parse(joinLink)
	if err != nil || u.Scheme != "https" || u.Host == "" || u.Path != "/meeting/register/join" {
		return joinLink
	}
	q := u.Query()
	sessionID := q.Get("sessionId")
	registerKey := q.Get("registerKey")
	if sessionID == "" || registerKey == "" {
		return joinLink
	}

	participantQuery := url.Values{
		"key":         {sessionID},
		"registerKey": {registerKey},
	}
	if uname := q.Get("uname"); uname != "" {
		participantQuery.Set("uname", uname)
	}
	if lastName := q.Get("lastname"); lastName != "" {
		participantQuery.Set("lastname", lastName)
	}
	u.Path = "/meeting/webinar-participant.do"
	u.RawQuery = participantQuery.Encode()
	u.Fragment = ""
	return u.String()
}

func snippet(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 300 {
		s = s[:300]
	}
	return s
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" {
			return v
		}
	}
	return ""
}

func splitName(full string) (first, last string) {
	parts := strings.Fields(strings.TrimSpace(full))
	switch len(parts) {
	case 0:
		return "Student", "-"
	case 1:
		return parts[0], "-"
	default:
		return parts[0], strings.Join(parts[1:], " ")
	}
}
