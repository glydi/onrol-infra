-- Converted-lead students get the standard default password (onrol@ai) — the
-- same as manually-created accounts — instead of a random temp password. They
-- sign in with email, phone, or the auto-assigned 6-char login_id. Replace the
-- provisioning trigger function (the trigger already points at it) and reset
-- any already-provisioned students to the default so they can log in now.

CREATE OR REPLACE FUNCTION provision_converted_lead() RETURNS trigger AS $$
DECLARE
  v_label     text := lower(trim(NEW.course_id));
  v_username  text := NULLIF(regexp_replace(coalesce(NEW.phone,''), '\D', '', 'g'), '');
  v_phone     text := NULLIF(trim(NEW.phone), '');
  v_name      text := coalesce(NULLIF(trim(NEW.name), ''), 'Student');
  v_email     text;
  v_pwd       text;
  v_uid       uuid;
  v_course_id uuid;
BEGIN
  IF v_label IS NULL OR v_label = '' THEN
    RETURN NEW;
  END IF;

  v_email := CASE
    WHEN lower(trim(coalesce(NEW.email, ''))) <> '' THEN lower(trim(NEW.email))
    WHEN v_username IS NOT NULL THEN v_username || '@students.onrol.local'
    ELSE 'lead-' || NEW.lead_id || '@students.onrol.local'
  END;

  INSERT INTO courses (title, label, status, enroll_type)
  SELECT coalesce(NULLIF(trim(NEW.course_title), ''), v_label), v_label, 'draft', 'manual'
  WHERE NOT EXISTS (SELECT 1 FROM courses c WHERE lower(c.label) = v_label);

  SELECT id INTO v_course_id FROM courses WHERE lower(label) = v_label LIMIT 1;

  SELECT id INTO v_uid FROM users u
   WHERE u.email = v_email OR (v_username IS NOT NULL AND lower(u.username) = v_username)
   LIMIT 1;

  IF v_uid IS NULL THEN
    v_pwd := 'onrol@ai'; -- standard default password (was a random temp)
    INSERT INTO users (email, username, phone, full_name, password_hash, role, course_label)
    VALUES (v_email, v_username, v_phone, v_name, crypt(v_pwd, gen_salt('bf', 10)), 'student', v_label)
    RETURNING id INTO v_uid;
    INSERT INTO provisioning_log (user_id, full_name, username, email, temp_password, course_label)
    VALUES (v_uid, v_name, v_username, v_email, v_pwd, v_label);
  ELSE
    UPDATE users SET course_label = v_label, updated_at = now()
    WHERE id = v_uid AND course_label IS DISTINCT FROM v_label;
  END IF;

  IF v_course_id IS NOT NULL THEN
    INSERT INTO course_enrollments (course_id, user_id, status)
    VALUES (v_course_id, v_uid, 'active')
    ON CONFLICT (course_id, user_id) DO NOTHING;
  END IF;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'provision_converted_lead failed for lead %: %', NEW.lead_id, SQLERRM;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Reset already-provisioned students (created with random temp passwords) to the
-- default so the converted-lead accounts can sign in with onrol@ai.
UPDATE users u
SET password_hash = crypt('onrol@ai', gen_salt('bf', 10)), updated_at = now()
FROM provisioning_log pl
WHERE pl.user_id = u.id AND u.role = 'student';

UPDATE provisioning_log SET temp_password = 'onrol@ai' WHERE temp_password <> 'onrol@ai';
