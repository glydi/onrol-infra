-- Targeted broadcasts: extend announcements so staff can aim a post at everyone
-- ("all"), a batch ("batch" + batch_number), or a role ("role" + role) — on top
-- of the existing course-scoped announcements.
ALTER TABLE announcements ADD COLUMN IF NOT EXISTS audience     TEXT NOT NULL DEFAULT 'all';
ALTER TABLE announcements ADD COLUMN IF NOT EXISTS batch_number INTEGER;
ALTER TABLE announcements ADD COLUMN IF NOT EXISTS role         TEXT;
CREATE INDEX IF NOT EXISTS idx_announcements_created ON announcements(created_at DESC);
