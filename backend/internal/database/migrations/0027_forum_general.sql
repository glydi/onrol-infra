-- Allow "General" discussion threads that aren't tied to a specific course
-- (course_id NULL = General, visible to every signed-in learner).
ALTER TABLE forum_threads ALTER COLUMN course_id DROP NOT NULL;
