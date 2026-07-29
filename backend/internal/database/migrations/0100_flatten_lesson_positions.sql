-- Course content switched from day-grouped to a flat, manually-ordered list.
-- Existing lessons had positions scoped WITHIN each day (Day1: 0,1,2; Day2:
-- 0,1,2…), so ordering by position alone scrambles them. Renumber each lesson's
-- position to its rank in the OLD "day_number, position" order so the flat list
-- preserves the original sequence. Safe to re-run (deterministic).
WITH ranked AS (
    SELECT id,
           row_number() OVER (PARTITION BY module_id
                              ORDER BY day_number NULLS LAST, position, id) - 1 AS newpos
    FROM lessons
)
UPDATE lessons l SET position = r.newpos
FROM ranked r WHERE r.id = l.id AND l.position <> r.newpos;
