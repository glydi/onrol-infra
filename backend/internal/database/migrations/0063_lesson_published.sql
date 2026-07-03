-- Course materials (lessons) can be published or hidden, like assessments.
-- Default TRUE so all existing materials stay visible.
ALTER TABLE lessons ADD COLUMN IF NOT EXISTS is_published BOOLEAN NOT NULL DEFAULT TRUE;
