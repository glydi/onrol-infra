# Third-party integrations

Every external API in this project runs in **DEMO mode** (simulated, with dummy
data) until you provide its credentials. The feature works end-to-end either way
— demo mode just doesn't hit the real provider. To go live, set the env var(s)
below in **`/opt/onrol/.env`** on the server and restart the API
(`systemctl restart onrol`). Status is visible in the app at **CRM › Integrations**.

| Integration | Env var(s) | Used in | Demo behavior |
|---|---|---|---|
| **Razorpay** (payments) | `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET` | CRM › Invoices → "Payment link" | Returns a demo link `https://demo.pay.onrol.test/inv/<id>` |
| **WhatsApp** (Meta Cloud API) | `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_ID` | CRM › Lead → "Message" (WhatsApp); Campaigns | Logs the message to the lead timeline, marks it "logged" |
| **Email** (SES/SendGrid/…) | `EMAIL_API_KEY`, `EMAIL_FROM` | CRM › Campaigns (send); Lead → "Message" (Email) | Counts the audience, marks sent — no real email leaves |
| **Voice / IVR** (Twilio/Plivo/Exotel) | `VOICE_ACCOUNT_SID`, `VOICE_AUTH_TOKEN` | Voice module (calls) — _planned_ | n/a (UI only until wired) |
| **SMS** | `SMS_API_KEY` | CRM › Lead → "Message" (SMS) | Logs the message, marks "logged" |
| **AI** (Anthropic/OpenAI) | `AI_API_KEY` | AI features — _planned_ | n/a |

## Where to drop in the live call

Each integration has a `TODO(live)` marker in the Go backend where the real HTTP
call goes:

- `backend/internal/handlers/crm_integrations.go`
  - `SendLeadMessage` — WhatsApp / SMS / Email send (per-channel `TODO(live)`).
  - `CreatePaymentLink` — Razorpay payment-links API.
- Config is loaded in `backend/internal/config/config.go` (`Integrations` struct);
  the status endpoint is `GET /api/v1/manage/integrations`.

## Example: enabling Razorpay

```bash
# on the server
sudo sed -i '/^ZOHO_WEBINAR_BASE=/a RAZORPAY_KEY_ID=rzp_live_xxx\nRAZORPAY_KEY_SECRET=yyy' /opt/onrol/.env
sudo systemctl restart onrol
# CRM › Integrations now shows Razorpay = LIVE
```

Then implement the `TODO(live)` block in `CreatePaymentLink` (POST
`https://api.razorpay.com/v1/payment_links`) and redeploy the backend
(`bash scripts/deploy.sh backend`).

> Demo mode is intentional: it lets the whole product be demoed and tested with
> no paid accounts, and makes the integration points explicit.
