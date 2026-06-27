-- Three test accounts with NO device limit. max_devices is set high (999) which
-- bindDevice treats as unlimited (>= 99). Password is bcrypt-hashed via pgcrypto
-- so Go's bcrypt verifies it. Idempotent: re-running resets their password and
-- unlimited flag without creating duplicates.
INSERT INTO users (email, username, full_name, password_hash, role, max_devices, is_active)
VALUES
  ('test1@onrol.test', 'test1', 'Test User 1', crypt('onrol@ai', gen_salt('bf', 10)), 'student', 999, true),
  ('test2@onrol.test', 'test2', 'Test User 2', crypt('onrol@ai', gen_salt('bf', 10)), 'student', 999, true),
  ('test3@onrol.test', 'test3', 'Test User 3', crypt('onrol@ai', gen_salt('bf', 10)), 'student', 999, true)
ON CONFLICT (email) DO UPDATE
   SET max_devices = 999, is_active = true, password_hash = EXCLUDED.password_hash;
