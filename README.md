# Onrol Infra

Lean backend + infra for an EdTech live-streaming and VOD platform, sized for
**100–300 concurrent users** on Indian networks.

- **Architecture & rationale:** [ARCHITECTURE.md](ARCHITECTURE.md)
- **Stack:** Go + Fiber API, PostgreSQL, Docker Compose, nginx (TLS), Cloudflare
  R2 for VOD, Zoho Webinar for live.

## Quick start (local, with Docker)

```bash
cp .env.example .env          # then edit secrets
make docker-up                # postgres + api + nginx
curl http://localhost:8080/healthz
```

## Quick start (local, no Docker)

Stands up a user-space Postgres (no sudo) + the API, then runs the full
end-to-end smoke test:

```bash
scripts/dev_up.sh                       # terminal 1: Postgres + API on :8080
# terminal 2:
ADMIN_KEY=$(grep ADMIN_API_KEY .env | cut -d= -f2) scripts/smoke_test.sh
```

The smoke test exercises: register → device-bound login → 2-device-limit
enforcement → admin video (server-generated AES key) → enrollment-gated key
delivery → device-mismatch rejection → webinar live-join.

## ⚠️ Do this before building the Flutter app

Validate the two unverified Zoho assumptions (programmatic registrants +
unique join URLs):

```bash
# fill ZOHO_* in .env first
make zoho-spike
```

See [ARCHITECTURE.md §5](ARCHITECTURE.md#5-validate-first-checklist-do-before-writing-flutter).

## Layout

```
backend/
  cmd/server/        API entrypoint
  cmd/zoho-spike/    standalone Zoho API validator (run before designing live)
  internal/
    config/          env config
    database/        pgx pool + embedded SQL migrations
    models/          domain types
    auth/            JWT issue/verify
    middleware/      auth, device, attestation hook
    handlers/        health, auth, devices, hls, live
    zoho/            Zoho Webinar client
docker-compose.yml   postgres + api + nginx
nginx/               reverse proxy + TLS termination
scripts/             backup + HLS packaging helpers
```

## Security posture (read this)

Device limit and AES-128 HLS are **deterrents**, correctly scoped for this
audience — not unbreakable DRM. The honest boundaries are documented in
[ARCHITECTURE.md §2](ARCHITECTURE.md#2-the-five-corrections-why-this-repo-exists).
The one thing that needs real work to have teeth is **server-side attestation**
(`internal/middleware/attestation.go`).
