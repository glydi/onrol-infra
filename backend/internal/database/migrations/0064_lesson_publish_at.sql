-- Scheduled publishing: a material can be set to go live on a date. Until then
-- (publish_at in the future) it's hidden from students, even if is_published.
-- NULL = publish immediately (subject to is_published).
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS publish_at TIMESTAMPTZ;
