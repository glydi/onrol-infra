-- Video store HLS: track each uploaded video's transcode status and the HLS
-- master playlist URL. Source mp4 stays in R2; the player uses hls_url once ready
-- so playback is segmented + smooth (no stalls on big/4K files).
ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS status  TEXT NOT NULL DEFAULT 'ready';
ALTER TABLE media_assets ADD COLUMN IF NOT EXISTS hls_url TEXT NOT NULL DEFAULT '';
