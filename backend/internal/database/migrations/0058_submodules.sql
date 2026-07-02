-- Sub-modules: a module may nest under another module (one level of nesting).
-- parent_module_id NULL = a top-level module; non-NULL = a sub-module of that parent.
ALTER TABLE modules ADD COLUMN IF NOT EXISTS parent_module_id UUID REFERENCES modules(id) ON DELETE CASCADE;
CREATE INDEX IF NOT EXISTS idx_modules_parent ON modules(parent_module_id);
