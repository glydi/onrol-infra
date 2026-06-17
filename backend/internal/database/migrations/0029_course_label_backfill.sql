-- Every course gets a unique "Course ID" (label) so the admin portal can list and
-- match courses by a stable unique string — no duplicates. Courses created before
-- the ID field existed have label NULL; backfill them with a slug of their title,
-- de-duplicated within the backfilled set. The display title is left untouched
-- (it is the separate, student-facing name and may repeat).
WITH base AS (
  SELECT id,
         coalesce(
           NULLIF(btrim(regexp_replace(lower(coalesce(title, '')), '[^a-z0-9]+', '-', 'g'), '-'), ''),
           'course'
         ) AS slug
  FROM courses
  WHERE label IS NULL
),
ranked AS (
  SELECT id, slug,
         row_number() OVER (PARTITION BY slug ORDER BY id) AS rn
  FROM base
)
UPDATE courses c
SET label = CASE WHEN r.rn = 1 THEN r.slug ELSE r.slug || '-' || r.rn END
FROM ranked r
WHERE c.id = r.id;

-- (idx_courses_label — UNIQUE on lower(label) WHERE label IS NOT NULL — already
-- exists from migration 0027 and enforces no-duplicate Course IDs going forward.)
