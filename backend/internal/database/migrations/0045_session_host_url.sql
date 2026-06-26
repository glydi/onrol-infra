-- A live class can carry a separate HOST link (e.g. a Zoho host/start URL) that
-- only staff/the instructor use to start and record the session — distinct from
-- the join_url students use to attend.
ALTER TABLE class_sessions ADD COLUMN IF NOT EXISTS host_url TEXT NOT NULL DEFAULT '';
