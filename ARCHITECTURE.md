# Onrol — EdTech Live + VOD Platform Architecture

> **Target scale: 100–300 concurrent users (Indian networks).**
> This document is the corrected blueprint. The original spec was sound in its
> bones but overstated several security guarantees and over-provisioned compute.
> The corrections below are baked into this repo's code.

---

## 0. TL;DR for this scale

- **Compute is a non-issue.** Go + Fiber + Postgres on a single 2–4 vCPU / 4–8 GB
  VPS idles at 300 users. The only thing that scales hard is video, and that is
  fully offloaded to **Zoho Webinar** (live) and **Cloudflare R2 + CDN** (VOD).
- The real risks are **security claims that don't hold**, **vendor lock-in to
  Zoho**, and **no backup/DR story**. This repo addresses all three.

---

## 1. Component stack

| Layer | Choice | Notes |
|---|---|---|
| Mobile client | Flutter | Android + iOS |
| API / core logic | Go + Fiber | This repo |
| Database | PostgreSQL 16 | Single instance, Docker |
| VOD hosting | Cloudflare R2 + CDN | Zero egress — correct call for India |
| Live video | Zoho Webinar API | Offloaded; **validate before building (see §5)** |
| Deploy | Docker Compose on Ubuntu VPS | nginx TLS termination |

---

## 2. The five corrections (why this repo exists)

### 2.1 Device binding must be server-attested, not header-trusted ⚠️ critical

The original design enforced a 2-device limit using a client-sent
`X-Device-UUID` header described as a "hardcoded cryptographic hardware token."

**Problem:** there is no reliable immutable hardware ID on modern Android
(no IMEI/serial since Android 10) or iOS, and *any* client-sent header is
attacker-controlled. With mitmproxy or Frida an attacker pins one `device_id`
across 50 phones and the limit means nothing.

**Fix in this repo:**
- `device_id` is still accepted and stored, but treated as **untrusted** input.
- Each device row carries an `attestation_verified` flag.
- `internal/middleware/attestation.go` is the **server-side verification hook**
  for **Play Integrity API** (Android) and **App Attest / DeviceCheck** (iOS).
  Until you wire a real verifier, it runs in `ATTESTATION_MODE=log` (accept +
  record) so you can ship, then flip to `enforce` once mobile sends real tokens.
- The 2-device rule is enforced **server-side at login** against the `devices`
  table, not by trusting the client.

### 2.2 AES-128 HLS is a deterrent, not DRM

"No unencrypted files ever sit on disk" is true and irrelevant to a determined
attacker: if the player can decrypt, the key and the decoded frames are on the
device. AES-128 HLS stops **network sniffing and casual ripping** — the 90%.
It does **not** stop a rooted device with Frida.

**Decision for this scale:** AES-128 HLS + authenticated key delivery +
access logging is the right pragmatic choice. Real DRM (Widevine/FairPlay) is a
large lift and **not justified at 300 users**. This repo implements the key
endpoint (`/api/v1/hls/key/:video_id`) gated by auth + device + enrollment, and
logs every key fetch for forensics. We do **not** claim it is unbreakable.

### 2.3 Validate Zoho before building around it ⚠️ do this first

The entire live path assumes Zoho can (a) create registrants programmatically
and return **unique signed join URLs**, and (b) allow embedding that URL in a
WebView. Both are unverified vendor assumptions. See `cmd/zoho-spike` — run it
with real credentials **before** committing to the design.

### 2.4 One live path, not two

The original diagram drew both Zoho **and** a self-hosted SRS edge VPS. For 300
users, pick one. This repo assumes **Zoho is the live path** and omits the SRS
box. (Self-hosting SRS is a separate, much larger project — don't half-build
both.)

### 2.5 Backups are the actual resilience story

Single VPS + Compose = one box dies, everything's down. This matters far more
than SRS failover at this scale. See `scripts/backup.sh` (nightly `pg_dump` →
R2) and the restore note in §6.

---

## 3. Topology

```
                    ┌──────────────────────────────┐
  Flutter App ──────│      Cloudflare (proxy)       │
   (Android/iOS)    │  DNS proxy + WAF + VOD cache  │
        │           └───────────────┬──────────────┘
        │                           │ 443
        │                  ┌────────▼─────────┐
        │                  │   nginx (TLS)    │   Ubuntu VPS
        │                  └────────┬─────────┘   2-4 vCPU / 4-8 GB
        │                           │ :8080
        │                  ┌────────▼─────────┐  ┌──────────────┐
        │                  │  Go Fiber API    │──│ PostgreSQL   │
        │                  │  auth/device/HLS │  │ (Docker vol) │
        │                  └────────┬─────────┘  └──────────────┘
        │                           │ m2m (OAuth)
        │                  ┌────────▼─────────┐
        ├─ live (WebView) ─│  Zoho Webinar    │
        │                  └──────────────────┘
        └─ VOD (.ts/.m3u8) ── Cloudflare R2  (keys served by Go, not R2)
```

**Key principle:** R2 serves *encrypted* `.ts` + `.m3u8` only. The AES key never
lives in R2 — it is served by the Go API after auth/device/enrollment checks.

---

## 4. Request flows

### 4.1 Login + device binding (enforced server-side)
1. App → `POST /api/v1/auth/login` with email, password, `X-Device-UUID`,
   platform, and (optionally) an attestation token.
2. API verifies password (bcrypt), runs attestation hook, then:
   - device_id already bound → OK, bump `last_seen`.
   - new device + active count < `max_devices` (default 2) → bind.
   - new device + count ≥ limit → **reject** with the list of existing devices
     so the user can free a slot via `DELETE /api/v1/devices/:id`.
3. API issues a JWT carrying `user_id` + `device_id`.

### 4.2 HLS VOD playback
1. Player fetches `.m3u8` from Cloudflare (cached, encrypted).
2. Player hits `GET /api/v1/hls/key/:video_id` with JWT + `X-Device-UUID`.
3. API checks JWT valid, device active, user enrolled → returns 16-byte key,
   logs the access (user, device, ip, ua).

### 4.3 Live (Zoho) — embed-first
Zoho's self-serve plans expose an **embeddable registration widget** and a
**web-to-registration form**, not a clean backend→join-link API. The unique join
link is usually **emailed** to the registrant. So:

1. App → `POST /api/v1/live/:webinar_id/join` (auth + device required).
2. API loads the webinar's stored Zoho tokens, computes the embed URL
   (`…/meeting/register/embed?sessionId=…`, student email prefilled), and makes a
   **best-effort** server-side web-form registration.
3. If Zoho returns a join URL synchronously → `{mode:"join", url}` (cached).
   Otherwise → `{mode:"embed", url}` and the app loads the registration widget in
   `flutter_inappwebview`; the student registers + joins inside Zoho.
4. Per-student forensic identity comes from the **Flutter watermark overlay**
   keyed to the JWT account — not from what the student types into Zoho.

Run `cmd/zoho-spike` to learn which branch your account takes.

---

## 5. Validate-first checklist (do before writing Flutter)

- [ ] `cmd/zoho-spike` POSTs the web form and prints the result.
- [ ] Decide the branch: does a join URL come back (`mode:"join"`) or does Zoho
      email it (`mode:"embed"`)? The spike tells you.
- [ ] The embed URL (`…/register/embed?sessionId=…`) renders inside a WebView on
      a real device.
- [ ] Confirm Zoho plan pricing at your concurrent-attendee tier.

If the embed widget doesn't render in a WebView, the live design changes — find
out now, not after launch.

---

## 6. Operations

- **TLS:** nginx terminates; use Let's Encrypt (certbot) or Cloudflare origin certs.
- **Backups:** `scripts/backup.sh` → nightly `pg_dump | gzip` → R2. Test a restore
  quarterly: `gunzip < dump.sql.gz | psql $DATABASE_URL`.
- **Secrets:** never commit `.env`. Rotate `JWT_SECRET` and Zoho creds out of band.
- **Observability:** Fiber access logs + Postgres logs to stdout (Docker);
  ship to a log drain when you outgrow `docker logs`.

---

## 7. What this repo is NOT

- Not real DRM. Not a CDN. Not a transcoding pipeline (do HLS segmentation +
  AES-128 packaging offline with ffmpeg, upload to R2 — see `scripts/`).
- Not multi-region. At 300 users you do not need it.
