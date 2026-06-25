-- The questions table never had a created_at column, but ListQuestions sorts by
-- `ORDER BY position, created_at` — so listing a quiz's questions failed at the
-- query ("list failed", HTTP 500) and the console builder showed an empty list
-- even after questions were added. Add the column so the insertion-order sort
-- works. Existing rows get now(); new rows get their real insert time.
ALTER TABLE questions ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT now();
