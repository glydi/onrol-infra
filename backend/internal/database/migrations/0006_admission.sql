-- Add a "closed" admission mode (admin enrolls students directly; no self-enroll
-- and no requests). Gives the admin three clear modes: self | manual | closed.
ALTER TABLE courses DROP CONSTRAINT IF EXISTS courses_enroll_type_check;
ALTER TABLE courses ADD CONSTRAINT courses_enroll_type_check
    CHECK (enroll_type IN ('manual','self','cohort','closed'));
