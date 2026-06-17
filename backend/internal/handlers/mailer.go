package handlers

import (
	"fmt"
	"net/smtp"
	"os"
	"strings"
)

// sendEmail delivers a simple HTML email via SMTP. Configure with env:
//
//	SMTP_HOST, SMTP_PORT (default 587), SMTP_USER, SMTP_PASS, EMAIL_FROM
//
// Uses STARTTLS (port 587) as negotiated by net/smtp. Returns an error if SMTP
// isn't configured so callers can decide how to handle it.
func sendEmail(to, subject, htmlBody string) error {
	host := os.Getenv("SMTP_HOST")
	if host == "" {
		return fmt.Errorf("smtp not configured")
	}
	port := os.Getenv("SMTP_PORT")
	if port == "" {
		port = "587"
	}
	user := os.Getenv("SMTP_USER")
	pass := os.Getenv("SMTP_PASS")
	from := os.Getenv("EMAIL_FROM")
	if from == "" {
		from = user
	}

	var b strings.Builder
	b.WriteString("From: ONROL <" + from + ">\r\n")
	b.WriteString("To: " + to + "\r\n")
	b.WriteString("Subject: " + subject + "\r\n")
	b.WriteString("MIME-Version: 1.0\r\n")
	b.WriteString("Content-Type: text/html; charset=UTF-8\r\n\r\n")
	b.WriteString(htmlBody)

	var auth smtp.Auth
	if user != "" {
		auth = smtp.PlainAuth("", user, pass, host)
	}
	return smtp.SendMail(host+":"+port, auth, from, []string{to}, []byte(b.String()))
}

// otpEmailHTML renders the branded reset-code email.
func otpEmailHTML(code string) string {
	return `<div style="font-family:system-ui,Arial,sans-serif;max-width:480px;margin:0 auto;padding:24px;color:#22252d">
  <div style="font-weight:800;font-size:20px;letter-spacing:1px;color:#FF4F2B">ONROL</div>
  <h2 style="margin:16px 0 4px;font-size:18px">Password reset code</h2>
  <p style="color:#666;font-size:14px;margin:0 0 18px">Use this code to reset your password. It expires in 10 minutes.</p>
  <div style="font-size:34px;font-weight:800;letter-spacing:10px;color:#22252d;background:#FFF3EC;border-radius:12px;padding:16px;text-align:center">` + code + `</div>
  <p style="color:#999;font-size:12px;margin-top:18px">If you didn't request this, you can safely ignore this email.</p>
</div>`
}
