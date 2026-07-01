-- A dedicated QA/test account with NO device limit: max_devices is set high
-- (999), which bindDevice treats as unlimited. Everyone else stays strictly
-- capped at 2 devices. Password is bcrypt-hashed via pgcrypto so Go verifies it.
-- Idempotent: re-running resets the password + unlimited flag.
INSERT INTO users (email, username, full_name, password_hash, role, max_devices, is_active)
VALUES ('device-test@onrol.test', 'devicetest', 'Device Test (no device limit)',
        crypt('onrol@ai', gen_salt('bf', 10)), 'student', 999, true)
ON CONFLICT (email) DO UPDATE
   SET max_devices = 999, is_active = true, password_hash = EXCLUDED.password_hash;

-- Enrol it in every course so it can exercise all content.
INSERT INTO course_enrollments (course_id, user_id, status)
SELECT c.id, u.id, 'active'
FROM courses c CROSS JOIN users u
WHERE u.email = 'device-test@onrol.test'
ON CONFLICT (course_id, user_id) DO NOTHING;
