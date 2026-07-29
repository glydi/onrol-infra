-- Organise the video store into folders. A video with folder_id = NULL is
-- "Unfiled" (the old flat behaviour). Deleting a folder unfiles its videos.
CREATE TABLE IF NOT EXISTS video_folders (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS folder_id UUID REFERENCES video_folders(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_media_assets_folder ON media_assets(folder_id);
