-- Every user gets a short, unique login ID: 3 letters + 3 digits (e.g. "abc042").
-- Users can sign in with it; admins can see it. Auto-assigned on insert via a
-- trigger (any code path) and backfilled for existing users.
ALTER TABLE users ADD COLUMN IF NOT EXISTS login_id TEXT;

-- Generate a random unused 3-letter + 3-digit code.
CREATE OR REPLACE FUNCTION gen_login_id() RETURNS text AS $$
DECLARE
  letters constant text := 'abcdefghijklmnopqrstuvwxyz';
  code text;
BEGIN
  LOOP
    code := substr(letters, 1 + floor(random() * 26)::int, 1)
         || substr(letters, 1 + floor(random() * 26)::int, 1)
         || substr(letters, 1 + floor(random() * 26)::int, 1)
         || lpad(floor(random() * 1000)::int::text, 3, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM users WHERE login_id = code);
  END LOOP;
  RETURN code;
END;
$$ LANGUAGE plpgsql;

-- Backfill existing users one row at a time so each sees prior assignments.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM users WHERE login_id IS NULL LOOP
    UPDATE users SET login_id = gen_login_id() WHERE id = r.id;
  END LOOP;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS idx_users_login_id ON users(login_id);

-- Auto-assign on every insert unless one is already supplied.
CREATE OR REPLACE FUNCTION set_login_id() RETURNS trigger AS $$
BEGIN
  IF NEW.login_id IS NULL THEN
    NEW.login_id := gen_login_id();
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_set_login_id ON users;
CREATE TRIGGER trg_set_login_id BEFORE INSERT ON users
  FOR EACH ROW EXECUTE FUNCTION set_login_id();
