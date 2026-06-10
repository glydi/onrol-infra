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
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

// actionType is base64("Registrations") — the literal value Zoho's form uses.
const actionTypeRegistrations = "UmVnaXN0cmF0aW9ucw=="

type Config struct {
	WebinarBase string // e.g. https://webinar.zoho.in
}

type Client struct {
	cfg  Config
	http *http.Client
}

func New(cfg Config) *Client {
	if cfg.WebinarBase == "" {
		cfg.WebinarBase = "https://webinar.zoho.in"
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
