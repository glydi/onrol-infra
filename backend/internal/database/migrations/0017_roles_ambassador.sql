-- Multi-portal roles + Ambassador portal.
-- Expands the user role set to cover all six portals (LMS, Ambassador,
-- Franchise Partner, CRM, Accounts & Administration, College Partner).

ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check CHECK (role IN (
    'superadmin', 'manager', 'instructor', 'student',
    'ambassador', 'franchise_partner', 'employee', 'college_partner'
));

-- Ambassador profile — 1:1 with a user whose role is 'ambassador'.
CREATE TABLE IF NOT EXISTS ambassador_profiles (
    user_id    UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    code       TEXT NOT NULL UNIQUE,
    tier       TEXT NOT NULL DEFAULT 'standard',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Referrals submitted/tracked by an ambassador.
CREATE TABLE IF NOT EXISTS referrals (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ambassador_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name          TEXT NOT NULL,
    email         TEXT NOT NULL DEFAULT '',
    phone         TEXT NOT NULL DEFAULT '',
    status        TEXT NOT NULL DEFAULT 'new',
    reward_paise  BIGINT NOT NULL DEFAULT 0,
    notes         TEXT NOT NULL DEFAULT '',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT referrals_status_check CHECK (status IN ('new','contacted','enrolled','rewarded','rejected'))
);
CREATE INDEX IF NOT EXISTS referrals_ambassador_idx ON referrals (ambassador_id, created_at DESC);
CREATE INDEX IF NOT EXISTS referrals_status_idx ON referrals (status);
