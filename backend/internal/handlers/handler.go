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
	Zoho     *zoho.Client  // may be nil if Zoho isn't configured
	Push     *push.Service // may be nil if Web Push failed to initialise
}

func New(cfg config.Config, pool *pgxpool.Pool, jwtm *auth.Manager, att middleware.Attestor, z *zoho.Client) *Handlers {
	// Warm the live-news cache at boot and keep refreshing it on an interval so
	// the feed is always current — the first visitor never waits, and new
	// headlines appear without anyone having to request them.
	newsCache.startAutoRefresh()
	return &Handlers{Cfg: cfg, Pool: pool, JWT: jwtm, Attestor: att, Zoho: z}
}
