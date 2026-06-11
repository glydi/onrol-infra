# ONROL — Demo Guide (users, features, integrations)

Domain base: `187-127-178-100.sslip.io`. Each portal is on its own TLS subdomain
and is its own browser origin — **log in separately on each subdomain**. After a
deploy you may need to hard-refresh once (no service worker, so it's one-time).

================================================================================
## 1. USER ACCOUNTS (test logins)
================================================================================

All test accounts have the device limit removed (max_devices = 1,000,000).
Admins (manager/superadmin) can access every portal; each other role sees only
its own portal.

| Email (userid)          | Password       | Role              | Portal & URL                                   | Purpose                                              |
|-------------------------|----------------|-------------------|------------------------------------------------|------------------------------------------------------|
| admin@onrol.test        | Admin@2026     | manager (Admin)   | ANY subdomain                                  | Full admin of all 6 portals                          |
| mentor@onrol.test       | Mentor@2026    | instructor        | lms.187-127-178-100.sslip.io                   | Author courses, quizzes, grade, live classes         |
| student@onrol.test      | Student@2026   | student           | 187-127-178-100.sslip.io  (root)               | Student home: courses, assignments, live, certs      |
| ambassador@onrol.test   | Ambass@2026!   | ambassador        | ambassador.187-127-178-100.sslip.io            | Referral code, refer people, rewards                 |
| franchise@onrol.test    | Franch@2026!   | franchise_partner | franchise.187-127-178-100.sslip.io             | Branch dashboard, enrol students, revenue share      |
| employee@onrol.test     | Employ@2026!   | employee          | accounts. AND college. 187-127-178-100.sslip.io| File expenses; manage partner colleges               |

NOTE: CRM (crm.187-127-178-100.sslip.io) is admin-only — use admin@onrol.test.
      Admin also sees the admin view of every other portal on its subdomain.

================================================================================
## 2. ALL FUNCTIONALITIES
================================================================================

PLATFORM
- 6 role-based portals, each on its own TLS subdomain; one Flutter build routed by host.
- Roles: superadmin, manager, instructor, student, ambassador, franchise_partner, employee.
- Email-or-username login, device-bound JWT (admins exempt from device limit).
- Dark mode; always-fresh web (no service worker); squared admin UI.

LMS  —  lms.* (admin/mentor)  +  root / (student)
- Student: dashboard, my courses, course content + HLS video player, day-wise
  assignments + quiz-taking, schedule, live classes, certificates, progress,
  profile, notifications, streak/XP, explore & enroll, announcements.
- Admin/Mentor: course/module/lesson authoring, publish, quizzes & assignments
  (day numbers + questions), grading/submissions, live sessions (editable join
  links), enrollment requests, reports (completion/grades/attendance), people +
  batches, create users, assign courses, device management, announcements
  (all/batch/role), per-user notifications.

CRM  —  crm.* (admin only) — 18 tabs
- Leads (pipeline, activities, tasks), Deals, Accounts, Campaigns (email/WhatsApp
  broadcasts), Invoices + Payments, Forms (public intake -> auto-lead), Analytics,
  Funnel, My Day, Automation rules, Surveys, Reviews, Calendar, Newsfeed, Tickets,
  Affiliates + Commissions, Webhooks, Integrations.
- Lead actions: Message (WhatsApp/SMS/Email). Invoice actions: Payment link.

AMBASSADOR  —  ambassador.*
- Admin: manage ambassadors + all referrals (status + rewards).
- Ambassador: referral code, stats, refer people, earnings.

ACCOUNTS & ADMINISTRATION  —  accounts.*
- Admin: cash ledger (income/expense/balance), expense approval
  (pending -> approved -> paid/rejected), staff (create employee logins).
- Employee: file + track own expenses.

COLLEGE PARTNER  —  college.*
- Partner colleges (MOU status, contact, city), per-college cohorts with
  student/placement tracking, summary KPIs.

FRANCHISE PARTNER  —  franchise.*
- Admin: manage partners + all enrollments.
- Partner: branch dashboard (territory, code, revenue share), enrol students, revenue.

DEMO DATA
- All portals are seeded with realistic, timeline-spread example data.
- Files: backend/internal/database/seed_demo.sql (CRM + portals),
         backend/internal/database/seed_lms.sql (LMS). Both idempotent.
- Re-seed a fresh DB: sudo -u postgres psql onrol -f <file>.

================================================================================
## 3. WHERE TO ADD REAL API KEYS
================================================================================

Every external integration runs in DEMO mode (simulated, dummy data) until its
key is set. To go live: add the env var(s) to /opt/onrol/.env on the server,
then `systemctl restart onrol`. Status shows in CRM > Integrations (LIVE/DEMO).
Full detail: INTEGRATIONS.md.

| Integration | Env var(s)                              | Used in                          | Code to wire (TODO(live))                                  |
|-------------|-----------------------------------------|----------------------------------|------------------------------------------------------------|
| Razorpay    | RAZORPAY_KEY_ID, RAZORPAY_KEY_SECRET    | CRM > Invoices > Payment link    | handlers/crm_integrations.go -> CreatePaymentLink          |
| WhatsApp    | WHATSAPP_TOKEN, WHATSAPP_PHONE_ID       | CRM > Lead > Message; Campaigns  | crm_integrations.go -> SendLeadMessage (whatsapp case)     |
| Email       | EMAIL_API_KEY, EMAIL_FROM               | Campaigns; Lead > Message        | SendLeadMessage (email) + crm_modules.go -> SendBroadcast  |
| SMS         | SMS_API_KEY                             | CRM > Lead > Message             | crm_integrations.go -> SendLeadMessage (sms case)          |
| Voice / IVR | VOICE_ACCOUNT_SID, VOICE_AUTH_TOKEN     | Voice module (planned)           | (UI/data to come)                                          |
| AI          | AI_API_KEY                              | AI assist (planned)              | (to come)                                                  |

Config struct: backend/internal/config/config.go (Integrations).
Status endpoint: GET /api/v1/manage/integrations.

EXAMPLE — enable Razorpay:
    printf 'RAZORPAY_KEY_ID=rzp_live_xxx\nRAZORPAY_KEY_SECRET=yyy\n' | sudo tee -a /opt/onrol/.env
    sudo systemctl restart onrol
    # CRM > Integrations now shows Razorpay = LIVE
Then implement the TODO(live) block in CreatePaymentLink and:
    bash scripts/deploy.sh backend

================================================================================
## DEPLOY / OPS QUICK REFERENCE
================================================================================
- Deploy edits to the VPS:   bash scripts/deploy.sh            (backend + web)
                             bash scripts/deploy.sh backend|web
- Fresh server bring-up:     scripts/cloud_bootstrap.sh        (see scripts/CLOUD_BOOTSTRAP.md)
- Always `git pull --rebase origin main` before editing (see CLAUDE.md / AGENTS.md).
- Logs: journalctl -u onrol -f   |   Service: systemctl status onrol
- Config/secrets: /opt/onrol/.env
