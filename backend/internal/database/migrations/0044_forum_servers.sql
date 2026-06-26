-- Discord-like community forum: servers (global / course-wide / batch-wide) hold
-- text channels, channels hold messages. Visibility: global = everyone;
-- course = enrolled in the course; batch = enrolled in the course AND in that
-- batch number. Staff (instructor/manager/superadmin) see and manage all.
CREATE TABLE IF NOT EXISTS forum_servers (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT NOT NULL,
    scope        TEXT NOT NULL CHECK (scope IN ('global','course','batch')),
    course_id    UUID REFERENCES courses(id) ON DELETE CASCADE,
    batch_number INT,
    icon         TEXT NOT NULL DEFAULT '',
    position     INT NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS forum_channels (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    server_id  UUID NOT NULL REFERENCES forum_servers(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    position   INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS forum_messages (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    channel_id UUID NOT NULL REFERENCES forum_channels(id) ON DELETE CASCADE,
    user_id    UUID REFERENCES users(id) ON DELETE SET NULL,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_forum_channels_server  ON forum_channels(server_id, position);
CREATE INDEX IF NOT EXISTS idx_forum_messages_channel ON forum_messages(channel_id, created_at);
