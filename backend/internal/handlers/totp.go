package handlers

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// Minimal RFC 6238 TOTP (SHA-1, 6 digits, 30s step) — compatible with Google
// Authenticator, Authy, 1Password, etc. Stdlib only, no external deps.

var totpEnc = base32.StdEncoding.WithPadding(base32.NoPadding)

// generateTOTPSecret returns a fresh base32 (RFC 4648) secret.
func generateTOTPSecret() string {
	b := make([]byte, 20)
	_, _ = rand.Read(b)
	return totpEnc.EncodeToString(b)
}

// totpAuthURL builds the otpauth:// URI an authenticator app imports.
func totpAuthURL(secret, account string) string {
	label := url.PathEscape("ONROL:" + account)
	q := url.Values{}
	q.Set("secret", secret)
	q.Set("issuer", "ONROL")
	q.Set("algorithm", "SHA1")
	q.Set("digits", "6")
	q.Set("period", "30")
	return "otpauth://totp/" + label + "?" + q.Encode()
}

func totpCodeAt(secret string, counter uint64) (string, error) {
	key, err := totpEnc.DecodeString(strings.ToUpper(strings.TrimSpace(secret)))
	if err != nil {
		return "", err
	}
	var buf [8]byte
	binary.BigEndian.PutUint64(buf[:], counter)
	mac := hmac.New(sha1.New, key)
	mac.Write(buf[:])
	sum := mac.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	val := (uint32(sum[off])&0x7f)<<24 | (uint32(sum[off+1])&0xff)<<16 | (uint32(sum[off+2])&0xff)<<8 | (uint32(sum[off+3]) & 0xff)
	return fmt.Sprintf("%06d", val%1_000_000), nil
}

// totpValidate accepts a code within a ±1 step window (clock skew tolerance).
func totpValidate(secret, code string) bool {
	code = strings.TrimSpace(code)
	if len(code) != 6 || secret == "" {
		return false
	}
	base := time.Now().Unix() / 30
	for d := int64(-1); d <= 1; d++ {
		if c, err := totpCodeAt(secret, uint64(base+d)); err == nil && c == code {
			return true
		}
	}
	return false
}
