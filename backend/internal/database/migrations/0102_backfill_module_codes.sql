-- Backfill: give every existing course module & sub-module a code, put it in the
-- Module Store, and link it (store_code) so it shows in the store and is synced.
-- One store module is created per un-coded course module; its lessons are copied
-- in. Idempotent: only touches modules whose store_code IS NULL.
DO $$
DECLARE
    m       RECORD;
    newcode TEXT;
    sid     UUID;
BEGIN
    FOR m IN SELECT id, title FROM modules WHERE store_code IS NULL LOOP
        -- A short, unique code derived from the module id (admins identify by the
        -- title in the store; they can add friendlier codes for new modules).
        newcode := 'M-' || upper(left(replace(m.id::text, '-', ''), 8));
        WHILE EXISTS (SELECT 1 FROM module_store WHERE code = newcode) LOOP
            newcode := 'M-' || upper(left(replace(gen_random_uuid()::text, '-', ''), 8));
        END LOOP;

        INSERT INTO module_store (code, title) VALUES (newcode, COALESCE(NULLIF(m.title, ''), 'Module'))
            RETURNING id INTO sid;
        INSERT INTO module_store_lessons (store_module_id, title, type, body, video_id, day_number, downloadable, position)
            SELECT sid, title, type, COALESCE(body, ''), video_id, day_number, COALESCE(downloadable, true), position
            FROM lessons WHERE module_id = m.id;
        UPDATE modules SET store_code = newcode WHERE id = m.id;
    END LOOP;
END $$;
