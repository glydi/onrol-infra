-- Optional TOTP-based two-factor authentication for any account.
-- totp_secret holds the base32 shared secret; totp_enabled gates enforcement
-- at login. A secret may exist while disabled (pending verification).
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS totp_secret  TEXT,
  ADD COLUMN IF NOT EXISTS totp_enabled BOOLEAN NOT NULL DEFAULT FALSE;
