-- Strictly: a converted lead may ONLY ever create or touch a STUDENT account.
-- The instant-provision trigger previously matched an existing account by
-- email/phone regardless of role and enrolled/re-keyed it — so a lead whose
-- contact happened to match an instructor/manager/admin could pull that account
-- into a course as if a student. Harden it: match only role='student'; if the
-- identity already belongs to a non-student, skip entirely (never create,
-- enrol, or re-key). New accounts are always created as 'student'.
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

  -- Ensure the course exists (titled from course_title).
  INSERT INTO courses (title, label, status, enroll_type)
  SELECT coalesce(NULLIF(trim(NEW.course_title), ''), v_label), v_label, 'draft', 'manual'
  WHERE NOT EXISTS (SELECT 1 FROM courses c WHERE lower(c.label) = v_label);

  SELECT id INTO v_course_id FROM courses WHERE lower(label) = v_label LIMIT 1;

  -- Find an existing STUDENT account only.
  SELECT id INTO v_uid FROM users u
   WHERE u.role = 'student'
     AND (u.email = v_email OR (v_username IS NOT NULL AND lower(u.username) = v_username))
   LIMIT 1;

  IF v_uid IS NULL THEN
    -- No student match. If the identity already belongs to a NON-student, do
    -- nothing — never create a student over them, never enrol them.
    IF EXISTS (
      SELECT 1 FROM users u
       WHERE u.email = v_email OR (v_username IS NOT NULL AND lower(u.username) = v_username)
    ) THEN
      RETURN NEW;
    END IF;
    -- Create the student account and log the temp password.
    v_pwd := substr(translate(encode(gen_random_bytes(12), 'base64'), '+/=lIO01', 'xyzabc23'), 1, 10);
    INSERT INTO users (email, username, phone, full_name, password_hash, role, course_label)
    VALUES (v_email, v_username, v_phone, v_name, crypt(v_pwd, gen_salt('bf', 10)), 'student', v_label)
    RETURNING id INTO v_uid;
    INSERT INTO provisioning_log (user_id, full_name, username, email, temp_password, course_label)
    VALUES (v_uid, v_name, v_username, v_email, v_pwd, v_label);
  ELSE
    UPDATE users SET course_label = v_label, updated_at = now()
    WHERE id = v_uid AND course_label IS DISTINCT FROM v_label;
  END IF;

  -- Enrol the student (v_uid is guaranteed a student account here).
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
