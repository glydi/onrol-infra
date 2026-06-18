// Package config loads runtime configuration from the environment.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

// AttestationMode controls how strictly device attestation is enforced.
type AttestationMode string

const (
	AttestationOff     AttestationMode = "off"     // dev only: ignore attestation
	AttestationLog     AttestationMode = "log"     // record result, always allow
	AttestationEnforce AttestationMode = "enforce" // reject on failure
)

// Zoho holds the regional base for Zoho Webinar. Per-webinar tokens (embed
// session id, web-form digest/enc/sysId) live in the webinars DB table, not
// here, because they differ per webinar.
type Zoho struct {
	WebinarBase string // e.g. https://webinar.zoho.in (.in DC for India)
}

type Config struct {
	Env             string
	Port            string
	DatabaseURL     string
	JWTSecret       string
	JWTAccessTTL    time.Duration
	MaxDevices      int
	AttestationMode AttestationMode
	AdminAPIKey     string
	AppBaseURL      string // public origin of the web app/API (for HLS key URIs)
	Zoho            Zoho
	Integrations    Integrations
	R2              R2
}

// R2 holds Cloudflare R2 (S3-compatible) storage config for the video store.
// When AccessKey is empty, in-app upload is disabled (returns a clear error).
type R2 struct {
	AccountID  string // R2_ACCOUNT_ID
	AccessKey  string // R2_ACCESS_KEY_ID
	SecretKey  string // R2_SECRET_ACCESS_KEY
	Bucket     string // R2_BUCKET
	PublicBase string // R2_PUBLIC_BASE (e.g. https://pub-xxxx.r2.dev or a custom domain)
}

// Endpoint is the S3 API host (no scheme) for the minio client.
func (r R2) Endpoint() string { return r.AccountID + ".r2.cloudflarestorage.com" }

// Enabled reports whether uploads can run (creds + bucket present).
func (r R2) Enabled() bool {
	return r.AccountID != "" && r.AccessKey != "" && r.SecretKey != "" && r.Bucket != ""
}

// Integrations holds optional third-party API credentials. When a key is empty,
// the corresponding feature runs in DEMO mode (simulated, with dummy data) so
// the app works end-to-end without real credentials. Set the env var to go live.
type Integrations struct {
	RazorpayKey    string // RAZORPAY_KEY_ID    — payment links / orders
	RazorpaySecret string // RAZORPAY_KEY_SECRET
	WhatsAppToken  string // WHATSAPP_TOKEN      — WhatsApp Business (Meta) Cloud API
	WhatsAppPhone  string // WHATSAPP_PHONE_ID
	EmailAPIKey    string // EMAIL_API_KEY       — transactional email (SES/SendGrid/etc.)
	EmailFrom      string // EMAIL_FROM
	VoiceSID       string // VOICE_ACCOUNT_SID   — telephony/IVR (Twilio/Plivo/Exotel)
	VoiceToken     string // VOICE_AUTH_TOKEN
	SMSAPIKey      string // SMS_API_KEY         — SMS provider
	AIAPIKey       string // AI_API_KEY          — LLM provider (Anthropic/OpenAI)
}

func (c Config) IsProduction() bool { return c.Env == "production" }

// Load reads configuration from the environment, applying defaults and
// validating anything that would make the server unsafe to start.
func Load() (Config, error) {
	cfg := Config{
		Env:             getenv("APP_ENV", "development"),
		Port:            getenv("PORT", "8080"),
		DatabaseURL:     os.Getenv("DATABASE_URL"),
		JWTSecret:       os.Getenv("JWT_SECRET"),
		JWTAccessTTL:    getdur("JWT_ACCESS_TTL", 24*time.Hour),
		MaxDevices:      getint("MAX_DEVICES_PER_USER", 2),
		AttestationMode: AttestationMode(getenv("ATTESTATION_MODE", string(AttestationLog))),
		AdminAPIKey:     os.Getenv("ADMIN_API_KEY"),
		AppBaseURL:      strings.TrimRight(getenv("APP_BASE_URL", "https://lms.187-127-178-100.sslip.io"), "/"),
		Zoho: Zoho{
			WebinarBase: getenv("ZOHO_WEBINAR_BASE", "https://webinar.zoho.in"),
		},
		Integrations: Integrations{
			RazorpayKey:    os.Getenv("RAZORPAY_KEY_ID"),
			RazorpaySecret: os.Getenv("RAZORPAY_KEY_SECRET"),
			WhatsAppToken:  os.Getenv("WHATSAPP_TOKEN"),
			WhatsAppPhone:  os.Getenv("WHATSAPP_PHONE_ID"),
			EmailAPIKey:    os.Getenv("EMAIL_API_KEY"),
			EmailFrom:      getenv("EMAIL_FROM", "no-reply@onrol.test"),
			VoiceSID:       os.Getenv("VOICE_ACCOUNT_SID"),
			VoiceToken:     os.Getenv("VOICE_AUTH_TOKEN"),
			SMSAPIKey:      os.Getenv("SMS_API_KEY"),
			AIAPIKey:       os.Getenv("AI_API_KEY"),
		},
		R2: R2{
			AccountID:  os.Getenv("R2_ACCOUNT_ID"),
			AccessKey:  os.Getenv("R2_ACCESS_KEY_ID"),
			SecretKey:  os.Getenv("R2_SECRET_ACCESS_KEY"),
			Bucket:     getenv("R2_BUCKET", "onrol-vod"),
			PublicBase: os.Getenv("R2_PUBLIC_BASE"),
		},
	}

	if cfg.DatabaseURL == "" {
		return cfg, fmt.Errorf("DATABASE_URL is required")
	}
	if cfg.JWTSecret == "" {
		return cfg, fmt.Errorf("JWT_SECRET is required")
	}
	if cfg.IsProduction() && len(cfg.JWTSecret) < 32 {
		return cfg, fmt.Errorf("JWT_SECRET must be at least 32 bytes in production")
	}
	switch cfg.AttestationMode {
	case AttestationOff, AttestationLog, AttestationEnforce:
	default:
		return cfg, fmt.Errorf("invalid ATTESTATION_MODE %q", cfg.AttestationMode)
	}
	if cfg.MaxDevices < 1 {
		return cfg, fmt.Errorf("MAX_DEVICES_PER_USER must be >= 1")
	}
	return cfg, nil
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getint(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func getdur(key string, def time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}
