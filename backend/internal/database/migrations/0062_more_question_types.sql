-- More auto-gradable question types: multiple-response (multi), fill-in-the-blank
-- (fill), and numerical (numeric).
ALTER TABLE questions DROP CONSTRAINT IF EXISTS questions_type_check;
ALTER TABLE questions ADD CONSTRAINT questions_type_check
    CHECK (type IN ('mcq','truefalse','short','essay','upload','multi','fill','numeric'));
