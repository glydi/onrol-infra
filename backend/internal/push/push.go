// Package push implements self-hosted Web Push (VAPID, no third-party provider).
// The server holds a VAPID keypair (generated once, persisted in the DB) and
// pushes encrypted payloads straight to the browser push endpoints stored per
// user. Reaches the web app on desktop and on phones via the mobile browser or
// an installed PWA; it does not reach native app builds (those need FCM/APNs).
package push

import (
	"context"
	"encoding/json"
	"log"
	"net/http"

	webpush "github.com/SherClockHolmes/webpush-go"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Service sends Web Push notifications and manages subscriptions.
type Service struct {
	pool    *pgxpool.Pool
	pub     string
	priv    string
	subject string // VAPID "Subscriber" — a contact URL or mailto:
}

// New loads the VAPID keypair from the DB, generating and persisting one on the
// first run so deployment needs no manual key setup.
func New(ctx context.Context, pool *pgxpool.Pool, subject string) (*Service, error) {
	var pub, priv string
	err := pool.QueryRow(ctx, `SELECT public_key, private_key FROM push_keys WHERE id=TRUE`).Scan(&pub, &priv)
	if err != nil {
		gpriv, gpub, gerr := webpush.GenerateVAPIDKeys()
		if gerr != nil {
			return nil, gerr
		}
		if _, ierr := pool.Exec(ctx,
			`INSERT INTO push_keys (id, public_key, private_key) VALUES (TRUE,$1,$2) ON CONFLICT (id) DO NOTHING`,
			gpub, gpriv); ierr != nil {
			return nil, ierr
		}
		// Re-read so a concurrent boot that won the INSERT still gives us the
		// canonical row.
		if rerr := pool.QueryRow(ctx, `SELECT public_key, private_key FROM push_keys WHERE id=TRUE`).Scan(&pub, &priv); rerr != nil {
			return nil, rerr
		}
	}
	if subject == "" {
		subject = "https://localhost"
	}
	return &Service{pool: pool, pub: pub, priv: priv, subject: subject}, nil
}

// PublicKey is the VAPID application server key the browser subscribes with.
func (s *Service) PublicKey() string {
	if s == nil {
		return ""
	}
	return s.pub
}

// Subscribe stores (or refreshes) a browser push subscription for a user.
func (s *Service) Subscribe(ctx context.Context, userID, endpoint, p256dh, auth string) error {
	_, err := s.pool.Exec(ctx, `
		INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth)
		VALUES ($1,$2,$3,$4)
		ON CONFLICT (endpoint) DO UPDATE
		   SET user_id=EXCLUDED.user_id, p256dh=EXCLUDED.p256dh, auth=EXCLUDED.auth`,
		userID, endpoint, p256dh, auth)
	return err
}

// Unsubscribe drops a subscription by its endpoint.
func (s *Service) Unsubscribe(ctx context.Context, endpoint string) error {
	_, err := s.pool.Exec(ctx, `DELETE FROM push_subscriptions WHERE endpoint=$1`, endpoint)
	return err
}

// Payload is the JSON the service worker receives in the push event.
type Payload struct {
	Title string `json:"title"`
	Body  string `json:"body"`
	URL   string `json:"url,omitempty"`
	Tag   string `json:"tag,omitempty"`
}

// SendToUser pushes to every subscription of one user (respecting their pref).
func (s *Service) SendToUser(ctx context.Context, userID string, p Payload) {
	if s == nil {
		return
	}
	s.send(ctx, `
		SELECT ps.endpoint, ps.p256dh, ps.auth
		FROM push_subscriptions ps
		LEFT JOIN user_preferences up ON up.user_id = ps.user_id
		WHERE ps.user_id = $1 AND COALESCE(up.push_notifications, TRUE)`, p, userID)
}

// SendToUsers pushes to a set of users (batch/role/course audiences).
func (s *Service) SendToUsers(ctx context.Context, userIDs []string, p Payload) {
	if s == nil || len(userIDs) == 0 {
		return
	}
	s.send(ctx, `
		SELECT ps.endpoint, ps.p256dh, ps.auth
		FROM push_subscriptions ps
		LEFT JOIN user_preferences up ON up.user_id = ps.user_id
		WHERE ps.user_id = ANY($1) AND COALESCE(up.push_notifications, TRUE)`, p, userIDs)
}

// SendToAll pushes to every subscriber who hasn't disabled push (audience=all).
func (s *Service) SendToAll(ctx context.Context, p Payload) {
	if s == nil {
		return
	}
	s.send(ctx, `
		SELECT ps.endpoint, ps.p256dh, ps.auth
		FROM push_subscriptions ps
		LEFT JOIN user_preferences up ON up.user_id = ps.user_id
		WHERE COALESCE(up.push_notifications, TRUE)`, p)
}

// send runs the subscription query and delivers the payload to each, pruning any
// endpoint the push service reports as gone (404/410).
func (s *Service) send(ctx context.Context, query string, p Payload, args ...any) {
	body, err := json.Marshal(p)
	if err != nil {
		return
	}
	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		log.Printf("push: query subscriptions: %v", err)
		return
	}
	type sub struct{ endpoint, p256dh, auth string }
	var subs []sub
	for rows.Next() {
		var e, k, a string
		if err := rows.Scan(&e, &k, &a); err == nil {
			subs = append(subs, sub{e, k, a})
		}
	}
	rows.Close()

	for _, su := range subs {
		resp, err := webpush.SendNotification(body, &webpush.Subscription{
			Endpoint: su.endpoint,
			Keys:     webpush.Keys{P256dh: su.p256dh, Auth: su.auth},
		}, &webpush.Options{
			Subscriber:      s.subject,
			VAPIDPublicKey:  s.pub,
			VAPIDPrivateKey: s.priv,
			TTL:             86400,
		})
		if err != nil {
			log.Printf("push: send: %v", err)
			continue
		}
		code := resp.StatusCode
		_ = resp.Body.Close()
		if code == http.StatusNotFound || code == http.StatusGone {
			_, _ = s.pool.Exec(ctx, `DELETE FROM push_subscriptions WHERE endpoint=$1`, su.endpoint)
		}
	}
}
