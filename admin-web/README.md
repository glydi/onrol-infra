# ONROL Staff Console (HTML)

A plain-HTML, no-build staff console (Admin + Instructor LMS) that runs against
the **existing Go API** — the Flutter app stays for students. This is the Phase-1
scaffold from `/Users/mukesh/.claude/plans/idempotent-squishing-wave.md`; other
models extend it section-by-section.

## What's here
- `index.html` — login + app shell (sidebar, topbar, content).
- `style.css` — squared, dense, light/dark admin styling (no framework).
- `app.js` — device auth, API client, hash router, role-aware sidebar, and the
  **Courses** section fully wired (list → detail → tabs; Curriculum + Settings
  render real data). Every other sidebar section is a stub that names its exact
  API endpoint on screen.

## Stack & principles
- No build step, no runtime CDN deps. Vanilla JS (`fetch` + template strings).
  Alpine/HTMX can be layered per-screen later; nothing depends on them.
- Talks to the same backend at same-origin `/api/v1` (served under `/admin/` on
  the lms host, so the existing `/api` proxy + TLS are reused).

## Auth (important)
- Login: `POST /api/v1/auth/login` with header `X-Device-UUID` (a UUID generated
  once and kept in `localStorage`) and body
  `{email, password, portal:"any", platform:"web", model:"Staff Console"}`.
  `email` may be an email / phone / username / login-id.
- Client gates to staff roles (`superadmin|manager|instructor`); others are refused.
- Every API call sends `Authorization: Bearer <jwt>` **and** `X-Device-UUID`.
- **Device cap caveat:** accounts are limited to `max_devices` (default 2). A
  staff member already at the cap (e.g. mobile + one web) will get HTTP 409
  "device limit reached" — bump their `max_devices` or free a slot
  (`DELETE /api/v1/devices/:id`). Consider raising the cap for staff.

## How it's deployed
- Static files live at `/var/www/onrol-admin/` on the VPS.
- nginx (`/etc/nginx/sites-available/onrol-lms`) serves them under `/admin/`:
  ```nginx
  location = /admin { return 301 /admin/; }
  location /admin/ { alias /var/www/onrol-admin/; index index.html; try_files $uri $uri/ =404; }
  ```
- Live at: **https://lms.187-127-178-100.sslip.io/admin/**
- Redeploy: `bash admin-web/deploy.sh` (rsync only — the nginx block is already in place).

## Extending (the pattern)
Each section = list → detail. Copy the **Courses** view in `app.js`:
`VIEWS['courses']` (table) + `courseDetail()` (tabbed detail). The `NAV` array is
the information architecture; each stub item carries its `stub:` endpoint. Full IA
+ per-screen endpoint map: the plan file above.
