-- Auto slideshow for the live image album. When slideshow_at is set, the server
-- picks the current slide deterministically from the elapsed time, so every
-- viewer sees the SAME image and it advances on its own every slideshow_secs —
-- a mandatory, viewer-uncontrollable slideshow shown in place of the video.
ALTER TABLE class_sessions
	ADD COLUMN IF NOT EXISTS slideshow_at   timestamptz,
	ADD COLUMN IF NOT EXISTS slideshow_secs integer NOT NULL DEFAULT 8;
