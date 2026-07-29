-- Preserve the previous "Day 1 / Day 2 …" structure by converting each day into
-- a SUBMODULE (content is now grouped by module/submodule, not day folders).
-- For every top-level module that has day-numbered lessons, create one submodule
-- per day (using the custom day label if set, else "Day N"), move that day's
-- lessons into it, and clear their day_number. Idempotent: re-running finds no
-- day-numbered lessons left in a parent module, so it creates nothing new.
DO $$
DECLARE
    m   RECORD;
    d   RECORD;
    sub UUID;
    pos INT;
BEGIN
    FOR m IN SELECT id, course_id, batch_number FROM modules WHERE parent_module_id IS NULL LOOP
        pos := COALESCE((SELECT max(position) FROM modules WHERE parent_module_id = m.id), -1);
        FOR d IN SELECT DISTINCT day_number FROM lessons
                 WHERE module_id = m.id AND day_number IS NOT NULL
                 ORDER BY day_number LOOP
            pos := pos + 1;
            INSERT INTO modules (course_id, title, position, parent_module_id, batch_number)
            VALUES (
                m.course_id,
                COALESCE((SELECT label FROM module_day_labels WHERE module_id = m.id AND day_number = d.day_number),
                         'Day ' || d.day_number),
                pos, m.id, m.batch_number
            ) RETURNING id INTO sub;
            UPDATE lessons SET module_id = sub, day_number = NULL
            WHERE module_id = m.id AND day_number = d.day_number;
        END LOOP;
    END LOOP;
END $$;
