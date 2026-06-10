-- gen_random_uuid() is core since PG13; pgcrypto kept for older images / safety.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS users (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email         TEXT UNIQUE NOT NULL,
    phone         TEXT,
    full_name     TEXT NOT NULL,
    password_hash TEXT NOT NULL,
    max_devices   INT  NOT NULL DEFAULT 2,
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- device_id is client-supplied and UNTRUSTED. attestation_verified records
-- whether Play Integrity / App Attest confirmed it. See middleware/attestation.go.
CREATE TABLE IF NOT EXISTS devices (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id              UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id            TEXT NOT NULL,
    platform             TEXT,
    model                TEXT,
    attestation_verified BOOLEAN NOT NULL DEFAULT FALSE,
    is_active            BOOLEAN NOT NULL DEFAULT TRUE,
    first_seen           TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen            TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, device_id)
);
CREATE INDEX IF NOT EXISTS idx_devices_user_active ON devices(user_id) WHERE is_active;

-- VOD metadata. The AES-128 key lives here, never in R2.
CREATE TABLE IF NOT EXISTS videos (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title          TEXT NOT NULL,
    hls_path       TEXT NOT NULL,         -- prefix/key in the R2 bucket
    encryption_key BYTEA NOT NULL,        -- 16 bytes (AES-128)
    key_id         TEXT NOT NULL,         -- identifier referenced by the m3u8
    is_published   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT encryption_key_len CHECK (octet_length(encryption_key) = 16)
);

-- Who may watch what.
CREATE TABLE IF NOT EXISTS enrollments (
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    video_id   UUID NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
    granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, video_id)
);

-- Forensic trail for key delivery (helps trace leaks back to an account/device).
CREATE TABLE IF NOT EXISTS key_access_log (
    id         BIGSERIAL PRIMARY KEY,
    user_id    UUID NOT NULL,
    device_id  TEXT NOT NULL,
    video_id   UUID NOT NULL,
    ip         TEXT,
    user_agent TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_key_access_user ON key_access_log(user_id, created_at);

-- Cached Zoho registrant join URLs (one per user per webinar).
CREATE TABLE IF NOT EXISTS webinar_registrations (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    webinar_key   TEXT NOT NULL,
    registrant_id TEXT,
    join_url      TEXT,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, webinar_key)
);
