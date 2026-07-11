-- Live stream (HLS) option for a live class: an externally-produced live HLS
-- URL (e.g. Cloudflare Stream, fed by the presenter's OBS or a Zoho webinar
-- custom-RTMP simulcast). Students watch it in our own live-room player — just
-- the video, no join button, no third-party chrome. Unlike media_asset_id (a
-- transcoded recording re-served as a sliding window), this is a real live feed
-- played directly.
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS live_hls_url TEXT;
