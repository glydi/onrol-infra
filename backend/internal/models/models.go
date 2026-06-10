// Package models holds the domain types shared across handlers and storage.
package models

import "time"

type User struct {
	ID           string    `json:"id"`
	Email        string    `json:"email"`
	Phone        string    `json:"phone,omitempty"`
	FullName     string    `json:"full_name"`
	Role         string    `json:"role"`
	PasswordHash string    `json:"-"`
	MaxDevices   int       `json:"max_devices"`
	IsActive     bool      `json:"is_active"`
	CreatedAt    time.Time `json:"created_at"`
}

type Device struct {
	ID                  string    `json:"id"`
	UserID              string    `json:"user_id"`
	DeviceID            string    `json:"device_id"`
	Platform            string    `json:"platform,omitempty"`
	Model               string    `json:"model,omitempty"`
	AttestationVerified bool      `json:"attestation_verified"`
	IsActive            bool      `json:"is_active"`
	FirstSeen           time.Time `json:"first_seen"`
	LastSeen            time.Time `json:"last_seen"`
}

type Video struct {
	ID          string    `json:"id"`
	Title       string    `json:"title"`
	HLSPath     string    `json:"hls_path"`
	KeyID       string    `json:"key_id"`
	IsPublished bool      `json:"is_published"`
	CreatedAt   time.Time `json:"created_at"`
	// EncryptionKey is intentionally never serialized to JSON.
	EncryptionKey []byte `json:"-"`
}

type WebinarRegistration struct {
	ID           string    `json:"id"`
	UserID       string    `json:"user_id"`
	WebinarKey   string    `json:"webinar_key"`
	RegistrantID string    `json:"registrant_id,omitempty"`
	JoinURL      string    `json:"join_url,omitempty"`
	CreatedAt    time.Time `json:"created_at"`
}
