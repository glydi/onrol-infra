-- Let a class session carry a direct join link (Zoho/Meet/Jitsi/etc.) that the
-- admin or instructor pastes, in addition to the optional Zoho webinar binding.
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS join_url TEXT NOT NULL DEFAULT '';
