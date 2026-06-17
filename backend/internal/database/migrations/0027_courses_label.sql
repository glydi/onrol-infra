-- Real courses from course labels. Each distinct student course_label (the
-- program a converted lead came in for, e.g. 'aigeneralist') becomes an actual
-- courses row, so the labels show up as a managed course list. The label is kept
-- on the course as a stable key linking it back to the per-course queue; students
-- are NOT auto-enrolled — they stay in the course-label queue + batch flow.
ALTER TABLE courses ADD COLUMN IF NOT EXISTS label TEXT;
CREATE UNIQUE INDEX IF NOT EXISTS idx_courses_label ON courses (lower(label)) WHERE label IS NOT NULL;

-- Backfill: one draft course per distinct existing course_label that doesn't
-- already have a matching course. Idempotent — re-running inserts nothing new.
INSERT INTO courses (title, label, status, enroll_type)
SELECT DISTINCT u.course_label, u.course_label, 'draft', 'manual'
FROM users u
WHERE u.course_label IS NOT NULL
  AND trim(u.course_label) <> ''
  AND NOT EXISTS (
    SELECT 1 FROM courses c WHERE lower(c.label) = lower(u.course_label)
  );
