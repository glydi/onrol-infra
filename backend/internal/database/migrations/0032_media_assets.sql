-- Video store: a library of videos uploaded by admins to R2. Each lesson can
-- reference one of these by its public URL. Deleting a row does not delete the
-- R2 object unless the API removes it explicitly.
CREATE TABLE IF NOT EXISTS media_assets (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title        TEXT NOT NULL,
    object_key   TEXT NOT NULL,            -- key within the R2 bucket
    url          TEXT NOT NULL,            -- public playback URL
    content_type TEXT NOT NULL DEFAULT '',
    size_bytes   BIGINT NOT NULL DEFAULT 0,
    created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_media_created ON media_assets(created_at DESC);
