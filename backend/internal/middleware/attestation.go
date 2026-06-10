package middleware

import (
	"context"

	"github.com/onrol/lms-backend/internal/config"
)

// AttestationResult is what a real verifier returns after checking a platform
// attestation token (Play Integrity on Android, App Attest/DeviceCheck on iOS).
type AttestationResult struct {
	Verified bool
	Reason   string
}

// Attestor verifies that a device token genuinely came from a real, untampered
// app instance on a real device. This is the ONLY thing that gives the
// 2-device limit real teeth — without it, X-Device-UUID is just a spoofable
// header (see ARCHITECTURE.md §2.1).
//
// Implement this against:
//   - Android: Play Integrity API  (verify the integrity verdict server-side)
//   - iOS:     App Attest / DeviceCheck (verify the assertion server-side)
type Attestor interface {
	Verify(ctx context.Context, platform, deviceID, token string) AttestationResult
}

// stubAttestor is the placeholder used until a real verifier is wired in.
// Its behaviour depends on the configured mode:
//
//	off     -> not consulted at all (handlers skip attestation)
//	log     -> returns Verified=false with a reason; caller records but allows
//	enforce -> returns Verified=false; caller MUST reject
//
// In every mode it refuses to *claim* verification it didn't perform. Flip to a
// real Attestor and the rest of the code path already does the right thing.
type stubAttestor struct{}

func NewStubAttestor() Attestor { return stubAttestor{} }

func (stubAttestor) Verify(_ context.Context, _, _, token string) AttestationResult {
	if token == "" {
		return AttestationResult{Verified: false, Reason: "no attestation token supplied"}
	}
	return AttestationResult{Verified: false, Reason: "no real attestor configured (stub)"}
}

// AttestationDecision applies the configured mode to a verification result and
// reports whether the login/bind should be allowed and whether the device may
// be marked attestation_verified.
func AttestationDecision(mode config.AttestationMode, res AttestationResult) (allow, markVerified bool) {
	switch mode {
	case config.AttestationOff:
		return true, false
	case config.AttestationLog:
		return true, res.Verified
	case config.AttestationEnforce:
		return res.Verified, res.Verified
	default:
		return false, false
	}
}
