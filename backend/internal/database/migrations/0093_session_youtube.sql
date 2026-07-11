-- YouTube Live option for a live class: store the YouTube video id so the
-- student watches a clean, logo-masked, autoplaying embed in our live room
-- (no third-party join click). The presenter broadcasts the webinar to this
-- YouTube Live; we only embed the stream.
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS youtube_id TEXT;
