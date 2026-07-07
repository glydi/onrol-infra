# ONROL Staff Console (HTML)

A plain-HTML, no-build staff console (Admin + Instructor LMS) that runs against
the **existing Go API** — the Flutter app stays for students. Design brief + full
information architecture: `/Users/mukesh/.claude/plans/idempotent-squishing-wave.md`.

## Files
- `index.html` — login + app shell (sidebar, topbar, content). Loads `core.js`
  then every `view-*.js`, then boots on `DOMContentLoaded`.
- `style.css` — the design system: light/dark tokens, sidebar, dense tables,
  tabbed detail, cards, modals, forms, toasts, pills, skeletons. **The whole
  console is rendered UPPERCASE** (`body{text-transform:uppercase}`); text the
  user types and code/paths keep their true case.
- `core.js` — the shared contract: device auth + API client, hash router,
  role-aware sidebar (the `NAV` array = the IA), and the reusable component
  library (`dataTable`, `formModal`, `confirmModal`, `openModal`, `pageHead`,
  `pill`, `dl`, `statCards`, `btn`, `wire`, `toast`, `registerView`, `go`,
  `setBadge`, `setCrumbs`, …). Exposes everything to `window`. Also holds the
  Dashboard + Profile reference views.
- `view-*.js` — one file per sidebar section, each calls `registerView(id, fn)`
  and uses only the `core.js` helpers: `courses`, `live`, `mentor`, `students`,
  `enrollments`, `staff`, `announcements`, `communities`, `calendar`, `videos`,
  `reports`. **`view-courses.js` is the gold-standard reference** (list → tabbed
  detail); copy its shape for new sections.

## Stack & principles
- No build step, no runtime CDN deps. Vanilla JS (`fetch` + template strings).
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
  staff member already at the cap gets HTTP 409 "device limit reached" — bump
  their `max_devices` or free a slot (`DELETE /api/v1/devices/:id`).

## Deploy
- Served from a subfolder of the Flutter web root — `/var/www/onrol/admin/` — so the
  **existing** nginx `location /` (try_files) serves it as static files. **No nginx
  change needed.** Live at **https://lms.187-127-178-100.sslip.io/admin/**
- `scripts/deploy.sh web` excludes `admin/` from its `--delete`, so shipping the
  Flutter app never wipes the console.
- Redeploy (rsync only): `bash admin-web/deploy.sh`
- Hash-routed + no service worker on the app (`--pwa-strategy=none`), so there's no
  SPA-fallback or cache conflict with the student app sharing the root.

## Extending (the pattern)
Each section = list → detail. Copy **`view-courses.js`**: `registerView('x', …)`
renders a `dataTable`; a row click routes to `#/x/<id>` and a detail fn renders
tabs. Add the section to `NAV` in `core.js`, add a `<script src="view-x.js">` to
`index.html`. Use ONLY the exposed helpers; never invent backend endpoints
(check `backend/internal/router/router.go` first).
