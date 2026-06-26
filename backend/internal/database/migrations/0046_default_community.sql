-- Seed a default GLOBAL community that everyone can see, with a few starter
-- channels — but only if no global community exists yet (idempotent).
WITH seeded AS (
    INSERT INTO forum_servers (name, scope, icon, position)
    SELECT 'ONROL Community', 'global', '🌐', 0
    WHERE NOT EXISTS (SELECT 1 FROM forum_servers WHERE scope = 'global')
    RETURNING id
)
INSERT INTO forum_channels (server_id, name, position)
SELECT seeded.id, ch.name, ch.pos
FROM seeded
CROSS JOIN (VALUES ('general', 0), ('announcements', 1), ('help', 2)) AS ch(name, pos);
