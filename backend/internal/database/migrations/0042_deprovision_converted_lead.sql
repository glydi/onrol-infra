-- Auto-deprovision: deleting a converted-lead row removes the student account
-- that was auto-created from it. Strictly scoped to AUTO-PROVISIONED students
-- (present in provisioning_log) — a manually-created student or any staff member
-- who happens to share contact details is never touched. If the same person
-- still has another converted-lead row (e.g. converted under a second course),
-- the account is kept. Deleting the user cascades their enrolments, progress,
-- submissions, devices, etc. via existing ON DELETE CASCADE foreign keys.
CREATE OR REPLACE FUNCTION deprovision_converted_lead() RETURNS trigger AS $$
DECLARE
  v_username text := NULLIF(regexp_replace(coalesce(OLD.phone,''), '\D', '', 'g'), '');
  v_email    text;
BEGIN
  v_email := CASE
    WHEN lower(trim(coalesce(OLD.email,''))) <> '' THEN lower(trim(OLD.email))
    WHEN v_username IS NOT NULL THEN v_username || '@students.onrol.local'
    ELSE 'lead-' || OLD.lead_id || '@students.onrol.local'
  END;

  -- Keep the account if another converted-lead row still refers to this person.
  IF EXISTS (
    SELECT 1 FROM converted_leads_backup b
     WHERE lower(trim(coalesce(b.email,''))) = v_email
        OR (v_username IS NOT NULL AND regexp_replace(coalesce(b.phone,''),'\D','','g') = v_username)
  ) THEN
    RETURN OLD;
  END IF;

  -- Delete only the auto-provisioned student that matches this lead.
  DELETE FROM users u
   WHERE u.role = 'student'
     AND EXISTS (SELECT 1 FROM provisioning_log pl WHERE pl.user_id = u.id)
     AND (u.email = v_email OR (v_username IS NOT NULL AND lower(u.username) = v_username));

  RETURN OLD;
EXCEPTION WHEN OTHERS THEN
  -- Never let a cleanup hiccup block the lead deletion itself.
  RAISE WARNING 'deprovision_converted_lead failed for lead %: %', OLD.lead_id, SQLERRM;
  RETURN OLD;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_deprovision_converted_lead ON converted_leads_backup;
CREATE TRIGGER trg_deprovision_converted_lead
  AFTER DELETE ON converted_leads_backup
  FOR EACH ROW EXECUTE FUNCTION deprovision_converted_lead();
