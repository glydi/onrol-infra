// Package liverec turns a finished simulated-live class into an on-demand video
// lesson. Five minutes after a session ends, its recording is published as a
// video lesson under a per-course "Live Class Recordings" module (numbered by
// day: Day 1, Day 2, …) and the session drops off the student's live list. The
// class_sessions row is kept, so the class still shows in the calendar history.
package liverec

import (
	"context"
	"errors"
	"log"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const recModuleTitle = "Live Class Recordings"

// Start runs the conversion loop: a first pass shortly after boot, then every
// interval. Every step is idempotent (converted_at gates re-conversion).
func Start(pool *pgxpool.Pool, interval time.Duration) {
	go func() {
		time.Sleep(12 * time.Second)
		runOnce(pool)
		t := time.NewTicker(interval)
		defer t.Stop()
		for range t.C {
			runOnce(pool)
		}
	}()
}

type endedSession struct {
	id, courseID, title, videoURL, assetID string
}

func runOnce(pool *pgxpool.Pool) {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	rows, err := pool.Query(ctx, `
		SELECT cs.id::text, cs.course_id::text, cs.title,
		       COALESCE(NULLIF(ma.hls_url,''), ma.url, ''), cs.media_asset_id::text
		FROM class_sessions cs
		JOIN media_assets ma ON ma.id = cs.media_asset_id
		WHERE cs.converted_at IS NULL
		  AND COALESCE(NULLIF(ma.hls_url,''), NULLIF(ma.url,'')) IS NOT NULL
		  AND now() > COALESCE(cs.ends_at,
		        cs.starts_at + make_interval(secs => GREATEST(COALESCE(ma.duration_seconds,0), 7200)))
		      + interval '5 minutes'`)
	if err != nil {
		log.Printf("liverec: query failed: %v", err)
		return
	}
	var list []endedSession
	for rows.Next() {
		var s endedSession
		if err := rows.Scan(&s.id, &s.courseID, &s.title, &s.videoURL, &s.assetID); err != nil {
			rows.Close()
			log.Printf("liverec: scan failed: %v", err)
			return
		}
		list = append(list, s)
	}
	rows.Close()

	for _, s := range list {
		if err := convert(ctx, pool, s); err != nil {
			log.Printf("liverec: convert session %s failed: %v", s.id, err)
		}
	}
}

func convert(ctx context.Context, pool *pgxpool.Pool, s endedSession) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	// Ensure the per-course "Live Class Recordings" module.
	var moduleID string
	err = tx.QueryRow(ctx, `SELECT id FROM modules WHERE course_id=$1 AND title=$2 LIMIT 1`,
		s.courseID, recModuleTitle).Scan(&moduleID)
	if errors.Is(err, pgx.ErrNoRows) {
		if err = tx.QueryRow(ctx, `
			INSERT INTO modules (course_id, title, position)
			VALUES ($1, $2, COALESCE((SELECT max(position)+1 FROM modules WHERE course_id=$1), 0))
			RETURNING id`, s.courseID, recModuleTitle).Scan(&moduleID); err != nil {
			return err
		}
	} else if err != nil {
		return err
	}

	// Number recordings by day: the next Day N (and position) in that module.
	var day, pos int
	_ = tx.QueryRow(ctx,
		`SELECT COALESCE(max(day_number),0)+1, COALESCE(max(position),0)+1 FROM lessons WHERE module_id=$1`,
		moduleID).Scan(&day, &pos)

	title := s.title
	if title == "" {
		title = "Live class recording"
	}
	if _, err = tx.Exec(ctx, `
		INSERT INTO lessons (module_id, title, type, video_id, body, is_published, day_number, position)
		VALUES ($1, $2, 'video', $3, $4, true, $5, $6)`,
		moduleID, title, s.assetID, s.videoURL, day, pos); err != nil {
		return err
	}
	if _, err = tx.Exec(ctx, `UPDATE class_sessions SET converted_at=now() WHERE id=$1`, s.id); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
