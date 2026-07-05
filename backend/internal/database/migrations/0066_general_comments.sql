-- Allow "General" mentor questions that aren't tied to any module: module_id
-- becomes optional and a course_id is added so a comment can be scoped to the
-- whole course instead. Existing rows keep their module and get course_id
-- backfilled from it.
ALTER TABLE module_comments ALTER COLUMN module_id DROP NOT NULL;
ALTER TABLE module_comments
  ADD COLUMN IF NOT EXISTS course_id UUID REFERENCES courses(id) ON DELETE CASCADE;

UPDATE module_comments mc
   SET course_id = m.course_id
  FROM modules m
 WHERE m.id = mc.module_id AND mc.course_id IS NULL;

CREATE INDEX IF NOT EXISTS idx_module_comments_course
  ON module_comments (course_id, thread_user_id, created_at);
