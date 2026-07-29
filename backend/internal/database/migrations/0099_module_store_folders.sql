-- Organise the Module Store into folders (like the video store). A store module
-- with folder_id = NULL is "Unfiled". Deleting a folder unfiles its modules.
CREATE TABLE IF NOT EXISTS module_folders (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE module_store ADD COLUMN IF NOT EXISTS folder_id UUID REFERENCES module_folders(id) ON DELETE SET NULL;
CREATE INDEX IF NOT EXISTS idx_module_store_folder ON module_store(folder_id);
