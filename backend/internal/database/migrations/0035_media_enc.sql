-- Encrypted HLS for the video store: each asset gets a random AES-128 key. The
-- segments in R2 are encrypted with it; the key is served only to authenticated
-- users from the API, so the public segments are useless on their own (free,
-- no DRM licence). NOT full DRM — a determined user can extract the key — but it
-- stops casual download/redistribution.
ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS enc_key bytea;
