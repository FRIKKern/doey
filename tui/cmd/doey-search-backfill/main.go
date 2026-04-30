// doey-search-backfill — one-shot maintenance binary that backfills the
// task_urls and *_fts indexes for an existing project DB.
//
// The schema migration in store.ensureSchema() seeds tasks_fts and
// messages_fts via a one-time INSERT … SELECT for any rows that predate
// the FTS triggers, so an upgraded DB has FTS coverage immediately. This
// tool covers the URL-extraction pass — the schema cannot regex-extract
// URLs in pure SQL, so URLs from existing tasks need an out-of-band sweep.
//
// Usage:
//   doey-search-backfill -db /path/to/doey.db [-batch 500] [-resume]
//
// The tool is idempotent: re-running on an already-backfilled DB is safe
// because StoreURLs is DELETE-then-INSERT per (task_id, field). A
// watermark in the config table (`search_backfill_watermark`) lets the
// run resume after interrupt without rescanning earlier rows.
package main

import (
	"context"
	"database/sql"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	_ "modernc.org/sqlite"

	"github.com/doey-cli/doey/tui/internal/search"
	"github.com/doey-cli/doey/tui/internal/store"
)

const watermarkKey = "search_backfill_watermark"

func main() {
	var dbPath string
	var batch int
	var resume bool
	var verbose bool
	flag.StringVar(&dbPath, "db", defaultDBPath(), "Path to doey.db")
	flag.IntVar(&batch, "batch", 500, "Tasks per transaction")
	flag.BoolVar(&resume, "resume", false, "Resume from saved watermark instead of restarting from id=0")
	flag.BoolVar(&verbose, "verbose", false, "Log per-batch progress")
	flag.Parse()

	if dbPath == "" {
		fmt.Fprintln(os.Stderr, "doey-search-backfill: -db required (could not infer)")
		os.Exit(2)
	}

	s, err := store.Open(dbPath)
	if err != nil {
		log.Fatalf("open %s: %v", dbPath, err)
	}
	defer s.Close()
	db := s.DB()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Fprintln(os.Stderr, "doey-search-backfill: interrupt received, draining current batch then exiting")
		cancel()
	}()

	start := time.Now()
	taskCount, urlCount, err := backfillTaskURLs(ctx, db, batch, resume, verbose)
	if err != nil {
		log.Fatalf("backfillTaskURLs: %v", err)
	}
	if err := backfillFTS(db); err != nil {
		log.Fatalf("backfillFTS: %v", err)
	}

	fmt.Printf("doey-search-backfill: %d tasks scanned, %d URLs indexed in %s\n",
		taskCount, urlCount, time.Since(start).Round(time.Millisecond))
}

func defaultDBPath() string {
	cwd, err := os.Getwd()
	if err != nil {
		return ""
	}
	return filepath.Join(cwd, ".doey", "doey.db")
}

// backfillTaskURLs walks every task and every subtask/log row, calls
// search.StoreURLs for each text field, and advances a watermark in the
// config table so an interrupted run can be resumed. Returns (#tasks
// scanned, #URLs inserted, error).
func backfillTaskURLs(ctx context.Context, db *sql.DB, batch int, resume, verbose bool) (int, int, error) {
	var startID int64
	if resume {
		startID = readWatermark(db)
		if verbose {
			fmt.Fprintf(os.Stderr, "doey-search-backfill: resuming after task_id=%d\n", startID)
		}
	}

	totalTasks := 0
	totalURLs := 0

	for {
		if err := ctx.Err(); err != nil {
			return totalTasks, totalURLs, nil
		}

		rows, err := db.Query(`SELECT id,
		                              COALESCE(title,''),
		                              COALESCE(description,''),
		                              COALESCE(notes,''),
		                              COALESCE(acceptance_criteria,''),
		                              COALESCE(success_criteria,''),
		                              COALESCE(decision_log,''),
		                              COALESCE(result,'')
		                       FROM tasks
		                       WHERE id > ?
		                       ORDER BY id ASC
		                       LIMIT ?`, startID, batch)
		if err != nil {
			return totalTasks, totalURLs, fmt.Errorf("query tasks: %w", err)
		}

		type taskRow struct {
			id     int64
			fields map[string]string
		}
		var rowsBuf []taskRow
		for rows.Next() {
			var t taskRow
			t.fields = make(map[string]string, 7)
			var title, desc, notes, ac, sc, decision, result string
			if err := rows.Scan(&t.id, &title, &desc, &notes, &ac, &sc, &decision, &result); err != nil {
				rows.Close()
				return totalTasks, totalURLs, err
			}
			t.fields["title"] = title
			t.fields["description"] = desc
			t.fields["notes"] = notes
			t.fields["acceptance_criteria"] = ac
			t.fields["success_criteria"] = sc
			t.fields["decision_log"] = decision
			t.fields["result"] = result
			rowsBuf = append(rowsBuf, t)
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return totalTasks, totalURLs, err
		}
		rows.Close()

		if len(rowsBuf) == 0 {
			break
		}

		tx, err := db.Begin()
		if err != nil {
			return totalTasks, totalURLs, fmt.Errorf("begin: %w", err)
		}
		batchURLs := 0
		for _, t := range rowsBuf {
			for field, content := range t.fields {
				before := batchURLs
				n, err := storeURLsCount(tx, t.id, field, content)
				if err != nil {
					_ = tx.Rollback()
					return totalTasks, totalURLs, fmt.Errorf("storeURLs task=%d field=%s: %w", t.id, field, err)
				}
				batchURLs = before + n
			}
			startID = t.id
		}
		if err := writeWatermarkTx(tx, startID); err != nil {
			_ = tx.Rollback()
			return totalTasks, totalURLs, err
		}
		if err := tx.Commit(); err != nil {
			return totalTasks, totalURLs, fmt.Errorf("commit: %w", err)
		}

		totalTasks += len(rowsBuf)
		totalURLs += batchURLs
		if verbose {
			fmt.Fprintf(os.Stderr, "doey-search-backfill: batch up to id=%d (+%d urls)\n", startID, batchURLs)
		}

		if len(rowsBuf) < batch {
			break
		}
	}

	// Subtasks + task_log fields — extracted under stable composite field names
	// matching the live write hooks in tasks.go.
	if err := backfillSubtaskURLs(ctx, db, batch, verbose, &totalURLs); err != nil {
		return totalTasks, totalURLs, err
	}
	if err := backfillTaskLogURLs(ctx, db, batch, verbose, &totalURLs); err != nil {
		return totalTasks, totalURLs, err
	}

	return totalTasks, totalURLs, nil
}

func backfillSubtaskURLs(ctx context.Context, db *sql.DB, batch int, verbose bool, urlAcc *int) error {
	rows, err := db.Query(`SELECT task_id, seq, COALESCE(title,'') FROM subtasks ORDER BY task_id, seq`)
	if err != nil {
		return fmt.Errorf("query subtasks: %w", err)
	}
	defer rows.Close()

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	count := 0
	for rows.Next() {
		if err := ctx.Err(); err != nil {
			_ = tx.Rollback()
			return nil
		}
		var taskID int64
		var seq int
		var title string
		if err := rows.Scan(&taskID, &seq, &title); err != nil {
			_ = tx.Rollback()
			return err
		}
		field := fmt.Sprintf("subtask:%d:title", seq)
		n, err := storeURLsCount(tx, taskID, field, title)
		if err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("subtask urls task=%d seq=%d: %w", taskID, seq, err)
		}
		*urlAcc += n
		count++
		if count%batch == 0 {
			if err := tx.Commit(); err != nil {
				return err
			}
			tx, err = db.Begin()
			if err != nil {
				return err
			}
			if verbose {
				fmt.Fprintf(os.Stderr, "doey-search-backfill: subtasks scanned=%d\n", count)
			}
		}
	}
	if err := rows.Err(); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

func backfillTaskLogURLs(ctx context.Context, db *sql.DB, batch int, verbose bool, urlAcc *int) error {
	rows, err := db.Query(`SELECT id, task_id, COALESCE(title,''), COALESCE(body,'') FROM task_log ORDER BY id`)
	if err != nil {
		return fmt.Errorf("query task_log: %w", err)
	}
	defer rows.Close()

	tx, err := db.Begin()
	if err != nil {
		return err
	}
	count := 0
	for rows.Next() {
		if err := ctx.Err(); err != nil {
			_ = tx.Rollback()
			return nil
		}
		var id, taskID int64
		var title, body string
		if err := rows.Scan(&id, &taskID, &title, &body); err != nil {
			_ = tx.Rollback()
			return err
		}
		nT, err := storeURLsCount(tx, taskID, fmt.Sprintf("log:%d:title", id), title)
		if err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("log title urls id=%d: %w", id, err)
		}
		nB, err := storeURLsCount(tx, taskID, fmt.Sprintf("log:%d:body", id), body)
		if err != nil {
			_ = tx.Rollback()
			return fmt.Errorf("log body urls id=%d: %w", id, err)
		}
		*urlAcc += nT + nB
		count++
		if count%batch == 0 {
			if err := tx.Commit(); err != nil {
				return err
			}
			tx, err = db.Begin()
			if err != nil {
				return err
			}
			if verbose {
				fmt.Fprintf(os.Stderr, "doey-search-backfill: task_log scanned=%d\n", count)
			}
		}
	}
	if err := rows.Err(); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

// storeURLsCount delegates to search.StoreURLsTx and returns the number of
// URLs inserted for this (taskID, field). Counted by re-extracting from
// content — cheaper than COUNT(*) round-trips.
func storeURLsCount(tx *sql.Tx, taskID int64, field, content string) (int, error) {
	if err := search.StoreURLsTx(tx, taskID, field, content); err != nil {
		return 0, err
	}
	return len(search.ExtractURLs(content)), nil
}

// backfillFTS makes sure tasks_fts and messages_fts contain a row per
// source row. The schema migration in ensureSchema() does this on first
// open, but a doctor-driven repair after schema drift may need to reseed.
func backfillFTS(db *sql.DB) error {
	if _, err := db.Exec(`INSERT INTO tasks_fts(rowid, task_id, title, description, shortname)
	                     SELECT id, id, COALESCE(title,''), COALESCE(description,''), COALESCE(shortname,'')
	                     FROM tasks
	                     WHERE id NOT IN (SELECT rowid FROM tasks_fts)`); err != nil {
		return fmt.Errorf("tasks_fts backfill: %w", err)
	}
	if _, err := db.Exec(`INSERT INTO messages_fts(rowid, msg_id, body)
	                     SELECT id, id, COALESCE(body,'')
	                     FROM messages
	                     WHERE id NOT IN (SELECT rowid FROM messages_fts)`); err != nil {
		return fmt.Errorf("messages_fts backfill: %w", err)
	}
	return nil
}

func readWatermark(db *sql.DB) int64 {
	var v string
	if err := db.QueryRow(`SELECT value FROM config WHERE key = ?`, watermarkKey).Scan(&v); err != nil {
		return 0
	}
	var n int64
	_, _ = fmt.Sscanf(v, "%d", &n)
	return n
}

func writeWatermarkTx(tx *sql.Tx, taskID int64) error {
	_, err := tx.Exec(`INSERT INTO config(key, value, source) VALUES (?, ?, 'backfill')
	                   ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
		watermarkKey, fmt.Sprintf("%d", taskID))
	return err
}
