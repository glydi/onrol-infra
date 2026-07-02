-- Allow an 'upload' question type: the student uploads a file as their answer
-- (graded manually, like an essay).
ALTER TABLE questions DROP CONSTRAINT IF EXISTS questions_type_check;
ALTER TABLE questions ADD CONSTRAINT questions_type_check
    CHECK (type IN ('mcq','truefalse','short','essay','upload'));
