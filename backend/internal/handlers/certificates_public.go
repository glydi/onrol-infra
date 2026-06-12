package handlers

import (
	"fmt"
	"html"
	"time"

	"github.com/gofiber/fiber/v2"
)

// CertificatePage renders a printable HTML certificate for a serial. The serial
// is a long random capability, so the page is public — it doubles as a shareable
// verification link (like Coursera/Udemy verify URLs). Pass ?download=1 to make
// the page open the browser's print/save-as-PDF dialog automatically.
func (h *Handlers) CertificatePage(c *fiber.Ctx) error {
	serial := c.Params("serial")
	c.Set("Content-Type", "text/html; charset=utf-8")

	var name, course string
	var issued time.Time
	err := h.Pool.QueryRow(c.Context(),
		`SELECT u.full_name, co.title, cert.issued_at
		   FROM certificates cert
		   JOIN users u ON u.id = cert.user_id
		   JOIN courses co ON co.id = cert.course_id
		  WHERE cert.serial = $1`, serial).Scan(&name, &course, &issued)
	if err != nil {
		return c.Status(fiber.StatusNotFound).SendString(certNotFoundHTML(html.EscapeString(serial)))
	}

	autoPrint := c.Query("download") != "" || c.Query("print") != ""
	return c.SendString(certHTML(html.EscapeString(name), html.EscapeString(course), html.EscapeString(serial), issued, autoPrint))
}

func certHTML(name, course, serial string, issued time.Time, autoPrint bool) string {
	date := issued.Format("January 2, 2006")
	auto := ""
	if autoPrint {
		auto = `<script>window.addEventListener('load',function(){setTimeout(function(){window.print();},350);});</script>`
	}
	return fmt.Sprintf(`<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Certificate · %[2]s · ONROL</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Poppins:wght@400;500;600;700;800&family=Playfair+Display:wght@600;700&display=swap" rel="stylesheet">
<style>
  :root{ --orange:#FF4F2B; --orange2:#FF7A4D; --navy:#22252D; --grey:#888; --ink:#2b2b2b; }
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Poppins',system-ui,sans-serif;background:linear-gradient(135deg,#FFF6F1,#FDEAF6);
       min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:28px;color:var(--ink)}
  .cert{position:relative;width:100%%;max-width:920px;aspect-ratio:1.414/1;background:#fff;border-radius:18px;
        box-shadow:0 30px 80px rgba(0,0,0,.18);overflow:hidden;padding:54px 60px;display:flex;flex-direction:column}
  .cert::before{content:"";position:absolute;inset:14px;border:2px solid rgba(255,79,43,.30);border-radius:12px;pointer-events:none}
  .cert::after{content:"";position:absolute;inset:20px;border:1px solid rgba(255,79,43,.16);border-radius:9px;pointer-events:none}
  .bar{position:absolute;top:0;left:0;right:0;height:10px;background:linear-gradient(90deg,var(--orange),var(--orange2))}
  .brand{display:flex;align-items:center;gap:12px;z-index:1}
  .logo{width:46px;height:46px;border-radius:12px;background:linear-gradient(135deg,var(--orange),var(--orange2));
        display:flex;align-items:center;justify-content:center;color:#fff;font-weight:800;font-size:20px;box-shadow:0 8px 18px rgba(255,79,43,.35)}
  .brand .n{font-weight:800;font-size:20px;letter-spacing:1px;color:var(--navy)}
  .brand .s{font-size:11px;color:var(--grey);letter-spacing:3px;text-transform:uppercase}
  .body{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;z-index:1}
  .kicker{font-size:13px;letter-spacing:4px;text-transform:uppercase;color:var(--orange);font-weight:700}
  .title{font-family:'Playfair Display',serif;font-size:40px;font-weight:700;color:var(--navy);margin:6px 0 22px}
  .awarded{font-size:13px;color:var(--grey);letter-spacing:1px}
  .name{font-family:'Playfair Display',serif;font-size:46px;font-weight:700;color:var(--navy);margin:6px 0 4px}
  .rule{width:280px;height:2px;background:linear-gradient(90deg,transparent,var(--orange),transparent);margin:8px 0 22px}
  .for{font-size:14px;color:var(--ink)}
  .course{font-size:24px;font-weight:700;color:var(--orange);margin-top:6px}
  .foot{display:flex;justify-content:space-between;align-items:flex-end;z-index:1;gap:24px}
  .foot .lbl{font-size:10px;letter-spacing:2px;text-transform:uppercase;color:var(--grey)}
  .foot .val{font-size:14px;font-weight:600;color:var(--navy);margin-top:3px}
  .seal{width:84px;height:84px;border-radius:50%%;background:linear-gradient(135deg,var(--orange),var(--orange2));
        display:flex;align-items:center;justify-content:center;color:#fff;font-weight:800;font-size:11px;text-align:center;line-height:1.2;
        box-shadow:0 10px 24px rgba(255,79,43,.4)}
  .bar-b{position:absolute;bottom:0;left:0;right:0;height:6px;background:linear-gradient(90deg,var(--orange2),var(--orange))}
  .actions{margin-top:24px;display:flex;gap:12px}
  .btn{font-family:'Poppins',sans-serif;font-size:14px;font-weight:700;border:none;cursor:pointer;border-radius:12px;padding:13px 26px;
       color:#fff;background:linear-gradient(135deg,var(--orange),var(--orange2));box-shadow:0 10px 24px rgba(255,79,43,.35)}
  .btn.ghost{background:#fff;color:var(--navy);border:1px solid rgba(0,0,0,.10);box-shadow:none}
  @media print{ body{background:#fff;padding:0} .actions{display:none} .cert{box-shadow:none;max-width:none;border-radius:0} @page{size:A4 landscape;margin:12mm} }
</style></head>
<body>
  <div class="cert">
    <div class="bar"></div>
    <div class="brand"><div class="logo">O</div><div><div class="n">ONROL</div><div class="s">Learn</div></div></div>
    <div class="body">
      <div class="kicker">Certificate of Completion</div>
      <div class="title">Certificate of Achievement</div>
      <div class="awarded">This certificate is proudly presented to</div>
      <div class="name">%[1]s</div>
      <div class="rule"></div>
      <div class="for">for successfully completing the course</div>
      <div class="course">%[2]s</div>
    </div>
    <div class="foot">
      <div><div class="lbl">Date Issued</div><div class="val">%[3]s</div></div>
      <div class="seal">ONROL<br>VERIFIED</div>
      <div style="text-align:right"><div class="lbl">Certificate ID</div><div class="val">%[4]s</div></div>
    </div>
    <div class="bar-b"></div>
  </div>
  <div class="actions">
    <button class="btn" onclick="window.print()">Download / Print PDF</button>
  </div>
  %[5]s
</body></html>`, name, course, date, serial, auto)
}

func certNotFoundHTML(serial string) string {
	return fmt.Sprintf(`<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Certificate not found · ONROL</title>
<style>body{font-family:system-ui,sans-serif;background:#FFF6F1;min-height:100vh;display:flex;align-items:center;justify-content:center;text-align:center;color:#22252D;padding:24px}
h1{font-size:22px;margin-bottom:8px}p{color:#888}</style></head>
<body><div><h1>Certificate not found</h1><p>No certificate matches ID <b>%s</b>.</p></div></body></html>`, serial)
}
