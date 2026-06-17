-- provision_students.sql — turn converted leads into LMS student accounts.
--
-- Each row in converted_leads_backup becomes a users row with role='student'
-- so the converted lead can sign in and use the LMS. Login is "phone + password":
-- the phone digits are stored as the account username, which the API login path
-- matches (auth.go: `WHERE email=$1 OR lower(username)=$1`), and a random temp
-- password is generated per account. Re-running is safe (idempotent): a lead
-- whose email or phone-username already maps to a user is skipped.
--
-- Requires the pgcrypto extension (already installed) for bcrypt: crypt() with
-- gen_salt('bf',10) produces a $2a$ hash that the Go bcrypt verifier accepts.
--
-- DRY RUN (no writes) — see exactly what would be created:
--   psql "$DATABASE_URL" -v apply=0 -f scripts/provision_students.sql
-- APPLY — create the accounts and print credentials as CSV:
--   psql "$DATABASE_URL" -v apply=1 -f scripts/provision_students.sql > students.csv
--
-- The :apply variable must be set; default below keeps an accidental run dry.

\if :{?apply}
\else
  \set apply 0
\endif

\set ON_ERROR_STOP on
BEGIN;

-- candidates: every converted lead, resolved to its final account fields and a
-- freshly generated temp password, EXCLUDING any that already have an account.
CREATE TEMP TABLE _prov ON COMMIT DROP AS
WITH src AS (
  SELECT
    b.lead_id,
    COALESCE(NULLIF(trim(b.name), ''), 'Student')              AS full_name,
    NULLIF(trim(b.phone), '')                                  AS phone,
    regexp_replace(COALESCE(b.phone, ''), '\D', '', 'g')       AS username,
    lower(trim(COALESCE(b.email, '')))                         AS raw_email,
    -- course label = the course the lead converted for. Prefer the explicit
    -- course_id; fall back to the old program/campaign tag. This queues the
    -- student under a course for batching and links to courses.label.
    COALESCE(
      NULLIF(trim(b.course_id), ''),
      NULLIF(trim(b.record->>'program'), ''),
      NULLIF(trim(b.campaign), '')
    )                                                          AS course_label,
    NULLIF(trim(COALESCE(b.course_title, '')), '')             AS course_title
  FROM converted_leads_backup b
),
resolved AS (
  SELECT
    lead_id, full_name, phone, course_label, course_title,
    NULLIF(username, '') AS username,
    -- users.email is NOT NULL UNIQUE; synthesize a placeholder when absent.
    CASE
      WHEN raw_email <> ''      THEN raw_email
      WHEN username  <> ''      THEN username || '@students.onrol.local'
      ELSE 'lead-' || lead_id || '@students.onrol.local'
    END AS email,
    -- 10-char unambiguous temp password.
    substr(translate(encode(gen_random_bytes(12), 'base64'),
                     '+/=lIO01', 'xyzabc23'), 1, 10) AS temp_password
  FROM src
)
-- One account per person: a lead may appear twice (same phone/email under two
-- courses). Keep a single row per email, preferring the one carrying a real
-- course_id (course_title present) so the student lands in the right course.
SELECT DISTINCT ON (r.email) r.*
FROM resolved r
WHERE NOT EXISTS (
  SELECT 1 FROM users u
  WHERE u.email = r.email
     OR (r.username IS NOT NULL AND lower(u.username) = r.username)
)
ORDER BY r.email,
         (r.course_title IS NOT NULL) DESC,
         (r.course_label IS NOT NULL) DESC;

\echo '--- leads to provision (not already accounts) ---'
SELECT full_name, phone, username, email, course_label, course_title FROM _prov ORDER BY course_label NULLS LAST, full_name;

\if :apply
  WITH ins AS (
    INSERT INTO users (email, username, phone, full_name, password_hash, role, course_label)
    SELECT email, username, phone, full_name,
           crypt(temp_password, gen_salt('bf', 10)), 'student', course_label
    FROM _prov
    RETURNING email
  )
  SELECT count(*) AS accounts_created FROM ins;

  -- Create a real course for each course_id that doesn't have one yet (idempotent),
  -- titled by the lead's course_title. New course_ids show up in the course list.
  INSERT INTO courses (title, label, status, enroll_type)
  SELECT DISTINCT ON (lower(p.course_label))
         COALESCE(p.course_title, p.course_label), p.course_label, 'draft', 'manual'
  FROM _prov p
  WHERE p.course_label IS NOT NULL AND trim(p.course_label) <> ''
    AND NOT EXISTS (SELECT 1 FROM courses c WHERE lower(c.label) = lower(p.course_label))
  ORDER BY lower(p.course_label);

  -- Re-key EXISTING students to their lead's course_id (when populated), so the
  -- student's course follows the source of truth. Matches by email or phone.
  UPDATE users u
  SET course_label = lower(trim(b.course_id)), updated_at = now()
  FROM converted_leads_backup b
  WHERE NULLIF(trim(b.course_id), '') IS NOT NULL
    AND u.role = 'student'
    AND ( (u.email <> '' AND lower(u.email) = lower(trim(b.email)))
       OR (u.username IS NOT NULL AND u.username = regexp_replace(coalesce(b.phone,''), '\D', '', 'g')) )
    AND u.course_label IS DISTINCT FROM lower(trim(b.course_id));

  -- Enrol students into the LMS course matching their lead's course_id — course_id
  -- is the key that puts a converted student into the course (course_enrollments).
  INSERT INTO course_enrollments (course_id, user_id, status)
  SELECT DISTINCT c.id, u.id, 'active'
  FROM converted_leads_backup b
  JOIN courses c ON lower(c.label) = lower(NULLIF(trim(b.course_id), ''))
  JOIN users u ON u.role = 'student' AND (
       (u.email <> '' AND lower(u.email) = lower(trim(b.email)))
    OR (u.username = regexp_replace(coalesce(b.phone,''), '\D', '', 'g')) )
  WHERE NULLIF(trim(b.course_id), '') IS NOT NULL
  ON CONFLICT (course_id, user_id) DO NOTHING;

  -- Keep each course's display title in sync with the lead's course_title.
  UPDATE courses c
  SET title = sub.course_title
  FROM (
    SELECT DISTINCT ON (lower(trim(course_id))) lower(trim(course_id)) AS cid, trim(course_title) AS course_title
    FROM converted_leads_backup
    WHERE NULLIF(trim(course_id), '') IS NOT NULL AND NULLIF(trim(course_title), '') IS NOT NULL
    ORDER BY lower(trim(course_id))
  ) sub
  WHERE lower(c.label) = sub.cid AND c.title IS DISTINCT FROM sub.course_title;

  \echo '--- credentials (CSV: name,phone,username,email,course_label,course_title,temp_password) ---'
  \copy (SELECT full_name, phone, username, email, course_label, course_title, temp_password FROM _prov ORDER BY course_label NULLS LAST, full_name) TO STDOUT WITH CSV HEADER

  COMMIT;
  \echo 'APPLIED: accounts created and committed.'
\else
  ROLLBACK;
  \echo 'DRY RUN: nothing written. Re-run with -v apply=1 to create accounts.'
\endif
