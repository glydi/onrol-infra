// Package handlers implements the HTTP API.
package handlers

import (
	"context"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/onrol/lms-backend/internal/auth"
	"github.com/onrol/lms-backend/internal/config"
	"github.com/onrol/lms-backend/internal/middleware"
	"github.com/onrol/lms-backend/internal/push"
	"github.com/onrol/lms-backend/internal/zoho"
)

// querier is satisfied by both *pgxpool.Pool and pgx.Tx, so helpers work inside
// or outside a transaction.
type querier interface {
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
}

// Handlers carries the dependencies shared by every route.
type Handlers struct {
	Cfg      config.Config
	Pool     *pgxpool.Pool
	JWT      *auth.Manager
	Attestor middleware.Attestor
	Zoho     *zoho.Client  // the default account's client; may be nil if unconfigured
	Push     *push.Service // may be nil if Web Push failed to initialise

	// zohoByAccount is one Zoho client per configured account id ("default",
	// "2025", …). zohoFor picks the right one for a webinar.
	zohoByAccount map[string]*zoho.Client
}

func New(cfg config.Config, pool *pgxpool.Pool, jwtm *auth.Manager, att middleware.Attestor, z *zoho.Client) *Handlers {
	// Warm the live-news cache at boot and keep refreshing it on an interval so
	// the feed is always current — the first visitor never waits, and new
	// headlines appear without anyone having to request them.
	newsCache.startAutoRefresh()
	// Build one client per configured Zoho account (shares bases/timezone).
	byAcct := map[string]*zoho.Client{}
	for _, a := range cfg.Zoho.Accounts {
		byAcct[a.ID] = zoho.New(zoho.Config{
			WebinarBase:  cfg.Zoho.WebinarBase,
			APIBase:      cfg.Zoho.APIBase,
			AccountsBase: cfg.Zoho.AccountsBase,
			OrgID:        a.OrgID,
			ClientID:     a.ClientID,
			ClientSecret: a.ClientSecret,
			RefreshToken: a.RefreshToken,
		})
	}
	return &Handlers{Cfg: cfg, Pool: pool, JWT: jwtm, Attestor: att, Zoho: z, zohoByAccount: byAcct}
}

// zohoFor returns the Zoho client for account [id], falling back to the default
// account's client (h.Zoho) when the id is empty/unknown or unconfigured.
func (h *Handlers) zohoFor(id string) *zoho.Client {
	if id != "" {
		if cl, ok := h.zohoByAccount[id]; ok {
			return cl
		}
	}
	if acc := h.Cfg.Zoho.Account(id); acc != nil {
		if cl, ok := h.zohoByAccount[acc.ID]; ok {
			return cl
		}
	}
	return h.Zoho
}
