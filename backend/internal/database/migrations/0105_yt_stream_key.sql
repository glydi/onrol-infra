-- In-app broadcasting: the host's YouTube "stream key" (from YouTube's Go Live
-- page). The browser captures camera/screen and publishes via WebRTC to the
-- relay (MediaMTX), which pushes RTMP to YouTube using this key. Stored per
-- session; only ever handed to the relay over a localhost, token-gated call.
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS yt_stream_key TEXT;
