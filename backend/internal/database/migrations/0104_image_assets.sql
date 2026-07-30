-- Image library (R2-backed), a sibling of the video store. Images are reusable
-- assets — course/thumbnail art, banners, slides, anything the admin wants to
-- drop in and reference by URL. Unlike videos there's no transcode/HLS step:
-- the object is served straight from R2.
CREATE TABLE IF NOT EXISTS image_folders (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS image_assets (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title        TEXT NOT NULL DEFAULT '',
    object_key   TEXT NOT NULL,
    url          TEXT NOT NULL,
    content_type TEXT NOT NULL DEFAULT '',
    size_bytes   BIGINT NOT NULL DEFAULT 0,
    folder_id    UUID REFERENCES image_folders(id) ON DELETE SET NULL,
    created_by   UUID,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_image_assets_folder ON image_assets(folder_id);
CREATE INDEX IF NOT EXISTS idx_image_assets_created ON image_assets(created_at DESC);
