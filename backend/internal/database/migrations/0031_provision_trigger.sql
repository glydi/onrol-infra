-- Instant auto-provisioning: the moment a converted lead gets a course_id (the
-- key), a student account is created, keyed to that course, and enrolled — right
-- inside the same write, no polling delay. The course_id is the key; a lead with
-- no course_id is ignored. The background job (every 2 min) remains as a catch-up.
-- Wrapped in an exception guard so a provisioning hiccup never blocks the CRM write.
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

  -- Find an existing account, else create one and log the temp password.
  SELECT id INTO v_uid FROM users u
   WHERE u.email = v_email OR (v_username IS NOT NULL AND lower(u.username) = v_username)
   LIMIT 1;

  IF v_uid IS NULL THEN
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

  -- Enrol into the course.
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

DROP TRIGGER IF EXISTS trg_provision_converted_lead ON converted_leads_backup;
CREATE TRIGGER trg_provision_converted_lead
  AFTER INSERT OR UPDATE OF course_id ON converted_leads_backup
  FOR EACH ROW EXECUTE FUNCTION provision_converted_lead();
