-- Course-label queue: tag each student with the course (program) they converted
-- for, so admins can see the per-course queue of students and form batches within
-- it. The label is a free-form course slug (e.g. 'aigeneralist'), not a courses.id.
ALTER TABLE users ADD COLUMN IF NOT EXISTS course_label TEXT;
CREATE INDEX IF NOT EXISTS idx_users_course_label ON users(course_label) WHERE course_label IS NOT NULL;
