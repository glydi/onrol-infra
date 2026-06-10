-- ============================================================================
-- LMS Manager/Admin role + full LMS domain model.
-- Roles: superadmin > manager > instructor > student.
-- A manager acts only within their scoped groups (department/institution) and
-- the descendants of those groups.
-- ============================================================================

-- --- Roles ------------------------------------------------------------------
ALTER TABLE users ADD COLUMN IF NOT EXISTS role TEXT NOT NULL DEFAULT 'student'
    CHECK (role IN ('superadmin','manager','instructor','student'));

-- --- Groups (departments / institutions / cohorts), hierarchical ------------
CREATE TABLE IF NOT EXISTS groups (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    type       TEXT NOT NULL DEFAULT 'department'
               CHECK (type IN ('institution','department','cohort')),
    parent_id  UUID REFERENCES groups(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_groups_parent ON groups(parent_id);

CREATE TABLE IF NOT EXISTS group_members (
    group_id      UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role_in_group TEXT NOT NULL DEFAULT 'member' CHECK (role_in_group IN ('member','leader')),
    PRIMARY KEY (group_id, user_id)
);

-- Which groups a manager is allowed to manage (scope root; includes descendants).
CREATE TABLE IF NOT EXISTS manager_scopes (
    user_id  UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    group_id UUID NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, group_id)
);

-- --- Courses & content ------------------------------------------------------
CREATE TABLE IF NOT EXISTS course_categories (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name      TEXT NOT NULL,
    parent_id UUID REFERENCES course_categories(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS courses (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title       TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    category_id UUID REFERENCES course_categories(id) ON DELETE SET NULL,
    group_id    UUID REFERENCES groups(id) ON DELETE SET NULL,   -- owning dept (scope)
    owner_id    UUID REFERENCES users(id) ON DELETE SET NULL,    -- creator/instructor
    status      TEXT NOT NULL DEFAULT 'draft'
                CHECK (status IN ('draft','published','archived')),
    enroll_type TEXT NOT NULL DEFAULT 'manual'
                CHECK (enroll_type IN ('manual','self','cohort')),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_courses_group ON courses(group_id);
CREATE INDEX IF NOT EXISTS idx_courses_owner ON courses(owner_id);

CREATE TABLE IF NOT EXISTS course_prerequisites (
    course_id        UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    prereq_course_id UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    PRIMARY KEY (course_id, prereq_course_id),
    CHECK (course_id <> prereq_course_id)
);

CREATE TABLE IF NOT EXISTS modules (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    title     TEXT NOT NULL,
    position  INT NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_modules_course ON modules(course_id);

-- Lessons / content items. type=scorm stores a package_url reference only.
CREATE TABLE IF NOT EXISTS lessons (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    module_id   UUID NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    type        TEXT NOT NULL DEFAULT 'text'
                CHECK (type IN ('video','text','scorm','xapi','link')),
    video_id    UUID REFERENCES videos(id) ON DELETE SET NULL,
    body        TEXT NOT NULL DEFAULT '',  -- text content / link URL / package URL
    position    INT NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_lessons_module ON lessons(module_id);

-- Course-level enrollment (distinct from per-video entitlement in `enrollments`).
CREATE TABLE IF NOT EXISTS course_enrollments (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id    UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status       TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','completed','dropped')),
    enrolled_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    enrolled_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    UNIQUE (course_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_cenroll_user ON course_enrollments(user_id);

-- Lesson completion tracking (drives completion reports).
CREATE TABLE IF NOT EXISTS lesson_progress (
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    lesson_id    UUID NOT NULL REFERENCES lessons(id) ON DELETE CASCADE,
    completed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, lesson_id)
);

-- --- Assessments & grading --------------------------------------------------
CREATE TABLE IF NOT EXISTS assessments (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id    UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    title        TEXT NOT NULL,
    type         TEXT NOT NULL DEFAULT 'quiz' CHECK (type IN ('quiz','assignment')),
    max_score    NUMERIC NOT NULL DEFAULT 100,
    due_at       TIMESTAMPTZ,
    is_published BOOLEAN NOT NULL DEFAULT FALSE,
    created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_assess_course ON assessments(course_id);

CREATE TABLE IF NOT EXISTS questions (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id UUID NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
    prompt        TEXT NOT NULL,
    type          TEXT NOT NULL DEFAULT 'mcq'
                  CHECK (type IN ('mcq','truefalse','short','essay')),
    options       JSONB NOT NULL DEFAULT '[]',   -- choices for mcq
    correct       TEXT NOT NULL DEFAULT '',       -- correct answer (auto-gradable types)
    points        NUMERIC NOT NULL DEFAULT 1,
    position      INT NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_questions_assess ON questions(assessment_id);

CREATE TABLE IF NOT EXISTS submissions (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    assessment_id UUID NOT NULL REFERENCES assessments(id) ON DELETE CASCADE,
    user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    answers       JSONB NOT NULL DEFAULT '{}',    -- {question_id: answer}
    score         NUMERIC,
    status        TEXT NOT NULL DEFAULT 'submitted'
                  CHECK (status IN ('submitted','graded','returned')),
    feedback      TEXT NOT NULL DEFAULT '',
    submitted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    graded_by     UUID REFERENCES users(id) ON DELETE SET NULL,
    graded_at     TIMESTAMPTZ,
    UNIQUE (assessment_id, user_id)
);
CREATE INDEX IF NOT EXISTS idx_submissions_assess ON submissions(assessment_id);

-- --- Communication ----------------------------------------------------------
CREATE TABLE IF NOT EXISTS announcements (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id  UUID REFERENCES courses(id) ON DELETE CASCADE,  -- null = global
    author_id  UUID REFERENCES users(id) ON DELETE SET NULL,
    title      TEXT NOT NULL,
    body       TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ann_course ON announcements(course_id, created_at);

CREATE TABLE IF NOT EXISTS messages (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    recipient_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    body         TEXT NOT NULL,
    read_at      TIMESTAMPTZ,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_msg_recipient ON messages(recipient_id, created_at);

CREATE TABLE IF NOT EXISTS forum_threads (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id  UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    author_id  UUID REFERENCES users(id) ON DELETE SET NULL,
    title      TEXT NOT NULL,
    locked     BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS forum_posts (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id  UUID NOT NULL REFERENCES forum_threads(id) ON DELETE CASCADE,
    author_id  UUID REFERENCES users(id) ON DELETE SET NULL,
    body       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_forum_posts_thread ON forum_posts(thread_id, created_at);

-- --- Scheduling (instructor-led) --------------------------------------------
CREATE TABLE IF NOT EXISTS class_sessions (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    course_id     UUID NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    title         TEXT NOT NULL,
    starts_at     TIMESTAMPTZ NOT NULL,
    ends_at       TIMESTAMPTZ,
    location      TEXT NOT NULL DEFAULT '',
    instructor_id UUID REFERENCES users(id) ON DELETE SET NULL,
    capacity      INT NOT NULL DEFAULT 0,            -- 0 = unlimited
    webinar_id    UUID REFERENCES webinars(id) ON DELETE SET NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sessions_course ON class_sessions(course_id, starts_at);

CREATE TABLE IF NOT EXISTS session_attendance (
    session_id UUID NOT NULL REFERENCES class_sessions(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status     TEXT NOT NULL DEFAULT 'present'
               CHECK (status IN ('present','absent','excused')),
    marked_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    marked_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, user_id)
);

CREATE TABLE IF NOT EXISTS session_waitlist (
    session_id UUID NOT NULL REFERENCES class_sessions(id) ON DELETE CASCADE,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    position   INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (session_id, user_id)
);

-- Promote the existing admin/student bootstrap: make the first manager easily.
-- (No data change here; managers are created via POST /api/v1/admin/users.)
