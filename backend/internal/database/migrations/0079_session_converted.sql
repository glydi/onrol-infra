-- When a simulated-live class ends, its recording is auto-published as a video
-- lesson 5 minutes later. converted_at marks that it's been turned into a lesson
-- (and drops it from the student's live list). NULL = not yet converted.
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS converted_at TIMESTAMPTZ;
