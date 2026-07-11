// Command server is the Onrol API entrypoint.
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
	_ "time/tzdata" // embed the IANA tz database so LoadLocation works anywhere

	"github.com/gofiber/fiber/v2"
	"github.com/gofiber/fiber/v2/middleware/logger"
	"github.com/gofiber/fiber/v2/middleware/recover"
	"github.com/joho/godotenv"

	"github.com/onrol/lms-backend/internal/auth"
	"github.com/onrol/lms-backend/internal/autoprovision"
	"github.com/onrol/lms-backend/internal/liverec"
	"github.com/onrol/lms-backend/internal/config"
	"github.com/onrol/lms-backend/internal/database"
	"github.com/onrol/lms-backend/internal/handlers"
	"github.com/onrol/lms-backend/internal/middleware"
	"github.com/onrol/lms-backend/internal/push"
	"github.com/onrol/lms-backend/internal/router"
	"github.com/onrol/lms-backend/internal/zoho"
)

func main() {
	// Best-effort local .env loading (no-op in Docker where env is injected).
	for _, p := range []string{".env", "../.env"} {
		_ = godotenv.Load(p)
	}

	cfg, err := config.Load()
	if err != nil {
		log.Fatalf("config: %v", err)
	}

	ctx := context.Background()
	pool, err := database.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("database: %v", err)
	}
	defer pool.Close()
	log.Printf("database connected, migrations applied")

	jwtm := auth.NewManager(cfg.JWTSecret, cfg.JWTAccessTTL)

	// TODO: replace the stub with a real Play Integrity / App Attest verifier.
	attestor := middleware.NewStubAttestor()

	// The Zoho client: embed/web-form paths need no secrets; the REST API v2
	// registration path activates when the OAuth fields below are set. Per-webinar
	// ids live in the DB. Always available; /live 404s if no webinar row.
	zClient := zoho.New(zoho.Config{
		WebinarBase:  cfg.Zoho.WebinarBase,
		APIBase:      cfg.Zoho.APIBase,
		AccountsBase: cfg.Zoho.AccountsBase,
		OrgID:        cfg.Zoho.OrgID,
		ClientID:     cfg.Zoho.ClientID,
		ClientSecret: cfg.Zoho.ClientSecret,
		RefreshToken: cfg.Zoho.RefreshToken,
	})

	h := handlers.New(cfg, pool, jwtm, attestor, zClient)

	// Self-hosted Web Push: load (or generate + persist) the VAPID keypair. On
	// failure we log and carry on — push endpoints then report disabled.
	if pushSvc, perr := push.New(ctx, pool, cfg.AppBaseURL); perr != nil {
		log.Printf("web push: init failed, push disabled: %v", perr)
	} else {
		h.Push = pushSvc
		log.Printf("web push ready (VAPID keypair loaded)")
	}

	// Allow the browser to upload video parts directly to R2 (fast path). Async
	// + best-effort; the client falls back to the proxy upload if this isn't set.
	go h.EnsureR2Cors(ctx)

	// Re-queue any transcode left stranded in 'processing' by a previous
	// restart, so videos (incl. simulated-live recordings) finish on their own.
	go h.ResumeStuckTranscodes(ctx)

	app := fiber.New(fiber.Config{
		AppName:               "onrol-api",
		ErrorHandler:          router.ErrorHandler,
		DisableStartupMessage: cfg.IsProduction(),
		ReadTimeout:           15 * time.Minute, // large video uploads stream in
		WriteTimeout:          15 * time.Minute,
		BodyLimit:             20 * 1024 * 1024 * 1024, // 20 GB — big video-store uploads (streamed, not buffered)
		StreamRequestBody:     true,                    // stream big bodies, don't buffer in RAM
	})
	app.Use(recover.New())
	app.Use(logger.New())

	router.Setup(app, h, jwtm, pool)

	// Auto-provision: converted leads (with a course_id) become enrolled students
	// on a schedule. Idempotent; logins are recorded in provisioning_log.
	autoprovision.Start(pool, 2*time.Minute)

	// Live recordings: 5 min after a simulated-live class ends, publish its
	// recording as a video lesson under the course's "Live Class Recordings".
	liverec.Start(pool, 1*time.Minute)

	// Graceful shutdown.
	go func() {
		if err := app.Listen(":" + cfg.Port); err != nil {
			log.Fatalf("listen: %v", err)
		}
	}()
	log.Printf("listening on :%s (env=%s, attestation=%s)", cfg.Port, cfg.Env, cfg.AttestationMode)

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Printf("shutting down...")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := app.ShutdownWithContext(shutdownCtx); err != nil {
		log.Printf("shutdown error: %v", err)
	}
}
