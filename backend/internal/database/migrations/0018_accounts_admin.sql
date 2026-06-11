-- Accounts & Administration portal (#5): expenses (with approval) + a cash
-- ledger. Amounts are integer paise. Simplified from onrol-crm's double-entry
-- acct_* tables into a practical back-office model.

CREATE TABLE IF NOT EXISTS acct_expenses (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    expense_date DATE NOT NULL DEFAULT current_date,
    vendor       TEXT NOT NULL DEFAULT '',
    category     TEXT NOT NULL DEFAULT '',
    amount       BIGINT NOT NULL DEFAULT 0,   -- paise (net)
    gst_amount   BIGINT NOT NULL DEFAULT 0,   -- paise
    status       TEXT NOT NULL DEFAULT 'pending',
    notes        TEXT NOT NULL DEFAULT '',
    created_by   UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT acct_expenses_status_check CHECK (status IN ('pending','approved','paid','rejected'))
);
CREATE INDEX IF NOT EXISTS acct_expenses_status_idx ON acct_expenses (status);
CREATE INDEX IF NOT EXISTS acct_expenses_by_idx ON acct_expenses (created_by, created_at DESC);

-- Cash ledger: manual income / expense entries for the books.
CREATE TABLE IF NOT EXISTS ledger_entries (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind        TEXT NOT NULL DEFAULT 'expense',
    category    TEXT NOT NULL DEFAULT '',
    amount      BIGINT NOT NULL DEFAULT 0,   -- paise
    description TEXT NOT NULL DEFAULT '',
    entry_date  DATE NOT NULL DEFAULT current_date,
    created_by  UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ledger_kind_check CHECK (kind IN ('income','expense'))
);
CREATE INDEX IF NOT EXISTS ledger_entries_date_idx ON ledger_entries (entry_date DESC);
