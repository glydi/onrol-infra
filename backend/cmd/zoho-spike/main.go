// Command zoho-spike answers the one question the live design hinges on:
// when you POST the Zoho web-registration form server-side, do you get a join
// URL back, or does Zoho just redirect to postregister and email the link?
//
// Fill the ZOHO_TEST_* vars in .env (copy the hidden values straight out of your
// webinar's embed registration form HTML), then: `make zoho-spike`.
//
// It prints the HTTP status, any Location redirect, a best-effort join-URL
// extraction, and the start of the response body so you can see exactly what
// Zoho does — then decide between the "embed" and "direct join URL" flows.
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/joho/godotenv"

	"github.com/onrol/lms-backend/internal/zoho"
)

func main() {
	for _, p := range []string{".env", "../.env"} {
		_ = godotenv.Load(p)
	}

	form := zoho.WebForm{
		URL:       envOr("ZOHO_TEST_WEBFORM_URL", "https://webinar.zoho.in/meeting/WebForm"),
		SysID:     os.Getenv("ZOHO_TEST_SYS_ID"),
		Digest:    os.Getenv("ZOHO_TEST_DIGEST"),
		Enc:       os.Getenv("ZOHO_TEST_ENC"),
		ReturnURL: envOr("ZOHO_TEST_RETURN_URL", "https://webinar.zoho.in/postregister"),
	}
	email := envOr("ZOHO_TEST_EMAIL", "spike-student@example.com")
	name := envOr("ZOHO_TEST_NAME", "Spike Student")

	var missing []string
	for k, v := range map[string]string{
		"ZOHO_TEST_SYS_ID": form.SysID, "ZOHO_TEST_DIGEST": form.Digest, "ZOHO_TEST_ENC": form.Enc,
	} {
		if v == "" {
			missing = append(missing, k)
		}
	}
	if len(missing) > 0 {
		fmt.Printf("✗ missing env (copy from your embed form HTML): %v\n", missing)
		os.Exit(1)
	}

	base := envOr("ZOHO_WEBINAR_BASE", "https://webinar.zoho.in")
	client := zoho.New(zoho.Config{WebinarBase: base})

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	fmt.Printf("POSTing registration for %q <%s> to %s ...\n\n", name, email, form.URL)
	res, err := client.RegisterViaWebForm(ctx, form, name, email, "Asia/Kolkata")
	if err != nil {
		fmt.Printf("✗ request failed: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("HTTP status : %d\n", res.StatusCode)
	fmt.Printf("Location    : %s\n", emptyDash(res.Location))
	fmt.Printf("Join URL    : %s\n", emptyDash(res.JoinURL))
	fmt.Printf("\n--- body (first 2KB) ---\n%s\n--- end body ---\n\n", res.BodySnip)

	switch {
	case res.JoinURL != "":
		fmt.Println("✓ A join URL came back. You CAN use the direct-join flow:")
		fmt.Println("  backend registers the student and hands the app a private join link.")
	case res.StatusCode >= 200 && res.StatusCode < 400:
		fmt.Println("• Registration accepted but NO join URL in the response.")
		fmt.Println("  Zoho most likely emails the link. Use the EMBED flow:")
		fmt.Println("  load /meeting/register/embed?sessionId=<id> in the WebView and let")
		fmt.Println("  the student register + join inside Zoho's widget.")
	default:
		fmt.Println("✗ Registration was rejected. Re-check the hidden token values, the DC")
		fmt.Println("  (.in vs .com), and whether the webinar is open for registration.")
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func emptyDash(s string) string {
	if s == "" {
		return "(none)"
	}
	return s
}
