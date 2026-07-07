-- Live image album / slideshow for simulated-live sessions. The host uploads
-- images (stored as data URIs, like the start/end banners), presents one at a
-- time to everyone (current_slide_id), and viewers can tap any to pop it up.
-- slides_rev is bumped whenever the album changes so clients refetch it (the
-- images are big, so they ride their own endpoint, not the polled /state).
CREATE TABLE IF NOT EXISTS live_slides (
	id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
	session_id uuid NOT NULL REFERENCES class_sessions(id) ON DELETE CASCADE,
	image      text NOT NULL,
	position   integer NOT NULL DEFAULT 0,
	created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_live_slides_session ON live_slides (session_id, position, created_at);

ALTER TABLE class_sessions
	ADD COLUMN IF NOT EXISTS current_slide_id uuid,
	ADD COLUMN IF NOT EXISTS slides_rev       integer NOT NULL DEFAULT 0;
