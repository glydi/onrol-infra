-- One-time codes for "forgot password" (OTP emailed to the user). The code is
-- stored hashed; rows expire and are single-use.
CREATE TABLE IF NOT EXISTS password_resets (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    code_hash  TEXT NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    used       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_pwreset_user ON password_resets(user_id, created_at DESC);
