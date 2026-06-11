# Working in this repo (read first)

> ## 🔴 ALWAYS `git pull` BEFORE YOU EDIT
> This repo is worked on by multiple developers and AI agents. **Before making
> any change, pull the latest `main`** so you don't edit a stale tree or create
> avoidable merge conflicts:
> ```bash
> git pull --rebase origin main
> ```
> Do this at the start of every session and again before you start a new edit if
> time has passed. If you cannot pull (offline/dirty tree), stop and resolve that
> first — do not edit on top of an unknown base.
>
> ## 🚀 ALWAYS DEPLOY YOUR EDITS TO THE VPS
> After your changes build and pass checks, **push them live**:
> ```bash
> bash scripts/deploy.sh          # builds + ships backend + web, verifies
> ```
> The machine holding this repo already has its SSH key accepted by the VPS, so
> this runs without prompts. Use `scripts/deploy.sh backend` or `… web` to ship
> just one side. The Go API auto-applies new migrations on restart, so shipping
> the binary rolls schema changes forward. Confirm `healthz` is ok and the web
> md5 MATCH line prints before considering the task done.

## What this is

- **Backend:** Go + Fiber API (`backend/`), PostgreSQL via pgx. SQL migrations in
  `backend/internal/database/migrations/` are **embedded and auto-applied on
  startup** — add a new numbered file, never edit an applied one.
- **App:** Flutter (`app/`) — one codebase builds web + mobile. The web app is
  served statically by nginx; it calls the API same-origin under `/api`.
- **CRM** lives in the same app, surfaced on its own `crm.<domain>` subdomain
  (see `app/lib/screens/crm_portal.dart`).

## Build / verify before you commit

```bash
# Backend
cd backend && go build ./...

# App
cd app && flutter analyze && flutter test
```

Both must be clean. For the web build use:
```bash
cd app && flutter build web --no-tree-shake-icons
```
(`--no-tree-shake-icons` is required — the UI uses icons chosen at runtime.)

## Deploy

- **One-command cloud bring-up:** `scripts/cloud_bootstrap.sh`
  (docs: `scripts/CLOUD_BOOTSTRAP.md`). Re-running pulls latest and rebuilds.
- The Go API auto-applies migrations on boot, so deploying a new binary is enough
  to roll schema changes forward.

## Conventions

- Add a new migration file (next number) for schema changes; don't mutate old ones.
- Admin/CRM panels use **squared buttons** (`PrimaryButton(square: true)`, radius 6).
- Keep new code in the style of the surrounding file (naming, comments, idioms).
- Commit/push only when asked; if on `main`, branch first.
