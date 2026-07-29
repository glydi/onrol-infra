-- A poster/thumbnail image (a frame grabbed during transcode, stored in R2) for
-- the video store grid.
ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS thumb_url TEXT;
