-- Per-course batch settings: a default batch size (students per batch, used when
-- auto-allocating this course's queue) and whether auto allocation is the default
-- mode. Drives the "batch settings" in the per-course batch portal.
ALTER TABLE courses ADD COLUMN IF NOT EXISTS batch_size INTEGER;
ALTER TABLE courses ADD COLUMN IF NOT EXISTS batch_auto BOOLEAN NOT NULL DEFAULT false;
