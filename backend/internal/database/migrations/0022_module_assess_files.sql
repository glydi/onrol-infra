-- More LMS admin control:
-- 1) Quizzes & assignments can be scoped to a specific module (not just course/day).
-- 2) Lessons can be documents (PDF / Word / PPT / any file) via a 'file' type.

ALTER TABLE assessments ADD COLUMN IF NOT EXISTS module_id UUID REFERENCES modules(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_assess_module ON assessments(module_id);

ALTER TABLE lessons DROP CONSTRAINT IF EXISTS lessons_type_check;
ALTER TABLE lessons ADD CONSTRAINT lessons_type_check
    CHECK (type IN ('video','text','scorm','xapi','link','file'));
