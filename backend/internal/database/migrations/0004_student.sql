-- Student/Learner-specific additions layered on the LMS core (0003).

-- Self-enrollment approval workflow (for courses where students must request).
CREATE TABLE IF NOT EXISTS enrollment_requests (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id  UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status     TEXT NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending','approved','rejected')),
    decided_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    decided_at TIMESTAMPTZ,
    UNIQUE (course_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_enroll_req_status ON enrollment_requests(status, course_id);

-- Certificates issued on course completion.
CREATE TABLE IF NOT EXISTS certificates (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    course_id UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    serial    TEXT NOT NULL UNIQUE,
    issued_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, course_id)
);

-- Per-user preferences (language, timezone, notification settings).
CREATE TABLE IF NOT EXISTS user_preferences (
    user_id             UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    language            TEXT NOT NULL DEFAULT 'en',
    timezone            TEXT NOT NULL DEFAULT 'Asia/Kolkata',
    email_notifications BOOLEAN NOT NULL DEFAULT TRUE,
    push_notifications  BOOLEAN NOT NULL DEFAULT TRUE,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
