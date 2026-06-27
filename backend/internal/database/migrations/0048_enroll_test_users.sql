-- Enrol the test accounts in every course so they can exercise all content
-- (including video streaming) without manual enrolment. Idempotent.
INSERT INTO course_enrollments (course_id, user_id, status)
SELECT c.id, u.id, 'active'
FROM courses c
CROSS JOIN users u
WHERE u.email IN ('test1@onrol.test', 'test2@onrol.test', 'test3@onrol.test')
ON CONFLICT (course_id, user_id) DO NOTHING;
