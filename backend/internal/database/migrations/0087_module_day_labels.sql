-- Custom names for the "Day N" groups inside a module. Lessons are grouped by
-- day_number and shown as "Day 1", "Day 2", …; this lets an admin rename a day
-- (e.g. "Kickoff", "Project Week") per module. No row = fall back to "Day N".
CREATE TABLE IF NOT EXISTS module_day_labels (
	module_id  UUID    NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
	day_number INTEGER NOT NULL,
	label      TEXT    NOT NULL,
	PRIMARY KEY (module_id, day_number)
);
