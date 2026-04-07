package runtime

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/doey-cli/doey/tui/internal/store"
)

// storeReader wraps a store.Store and converts store types to runtime types.
type storeReader struct {
	s            *store.Store
	lastTaskSync time.Time // throttle file-to-DB sync
}

// openStore tries to open .doey/doey.db. Returns nil if DB doesn't exist or can't be opened.
func openStore(projectDir string) *storeReader {
	if projectDir == "" {
		return nil
	}
	dbPath := filepath.Join(projectDir, ".doey", "doey.db")
	if _, err := os.Stat(dbPath); err != nil {
		return nil
	}
	s, err := store.Open(dbPath)
	if err != nil {
		return nil
	}
	return &storeReader{s: s}
}

func (sr *storeReader) close() {
	if sr != nil && sr.s != nil {
		sr.s.Close()
	}
}

// syncTaskFiles upserts all .task files into the SQLite store.
// Throttled to run at most once every 30 seconds.
func (sr *storeReader) syncTaskFiles(projectDir string) {
	if time.Since(sr.lastTaskSync) < 30*time.Second {
		return
	}
	tasksDir := filepath.Join(projectDir, ".doey", "tasks")
	sr.s.SyncTaskFiles(tasksDir)
	sr.lastTaskSync = time.Now()
}

// readTasks converts store tasks to runtime tasks, including subtasks and logs.
func (sr *storeReader) readTasks() []Task {
	storeTasks, err := sr.s.ListTasks("")
	if err != nil {
		return nil
	}
	tasks := make([]Task, 0, len(storeTasks))
	for _, st := range storeTasks {
		t := Task{
			ID:                 fmt.Sprintf("%d", st.ID),
			Title:              st.Title,
			Status:             st.Status,
			Category:           st.Type,
			Description:        st.Description,
			CreatedBy:          st.CreatedBy,
			AssignedTo:         st.AssignedTo,
			Team:               st.Team,
			Tags:               splitTags(st.Tags),
			AcceptanceCriteria: st.AcceptanceCriteria,
			Created:            st.CreatedAt,
			Updated:            st.UpdatedAt,
		}
		if st.PlanID != nil {
			t.PlanID = fmt.Sprintf("%d", *st.PlanID)
		}

		// Subtasks
		storeSubs, _ := sr.s.ListSubtasks(st.ID)
		for _, ss := range storeSubs {
			pane := ss.Assignee
			if pane == "" {
				pane = strconv.Itoa(ss.Seq)
			}
			t.Subtasks = append(t.Subtasks, Subtask{
				TaskID:      t.ID,
				Pane:        pane,
				Title:       ss.Title,
				Status:      ss.Status,
				Worker:      ss.Worker,
				Created:     ss.CreatedAt,
				CompletedAt: ss.CompletedAt,
				Reason:      ss.Reason,
			})
		}

		// Task log entries → Logs and DecisionLog
		logs, _ := sr.s.ListTaskLog(st.ID)
		var decisions []string
		for _, l := range logs {
			switch l.Type {
			case "decision":
				decisions = append(decisions, fmt.Sprintf("%d:%s", l.CreatedAt, l.Title))
			case "note":
				if t.Notes != "" {
					t.Notes += "\n"
				}
				t.Notes += l.Body
			default:
				entry := l.Body
				if entry == "" {
					entry = l.Title
				}
				if l.Author != "" {
					entry = "[" + l.Author + "] " + entry
				}
				t.Logs = append(t.Logs, TaskLog{
					Timestamp: l.CreatedAt,
					Entry:     entry,
				})
			}
		}
		if len(decisions) > 0 {
			t.DecisionLog = strings.Join(decisions, "\n")
		}

		tasks = append(tasks, t)
	}
	return tasks
}

// readPlans converts store plans to runtime plans.
func (sr *storeReader) readPlans() []Plan {
	storePlans, err := sr.s.ListPlans()
	if err != nil {
		return nil
	}
	plans := make([]Plan, 0, len(storePlans))
	for _, sp := range storePlans {
		plans = append(plans, Plan{
			ID:      int(sp.ID),
			Title:   sp.Title,
			Status:  sp.Status,
			Content: sp.Body,
			Created: formatUnixTime(sp.CreatedAt),
			Updated: formatUnixTime(sp.UpdatedAt),
		})
	}
	return plans
}

// readPaneStatuses reads all pane statuses from the store.
func (sr *storeReader) readPaneStatuses() map[string]PaneStatus {
	rows, err := sr.s.DB().Query(
		`SELECT pane_id, window_id, role, status, task_title, updated_at FROM pane_status ORDER BY pane_id`,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	statuses := make(map[string]PaneStatus)
	for rows.Next() {
		var paneID, windowID, role, status, taskTitle string
		var updatedAt int64
		if err := rows.Scan(&paneID, &windowID, &role, &status, &taskTitle, &updatedAt); err != nil {
			continue
		}
		ps := PaneStatus{
			Pane:    paneID,
			Status:  status,
			Task:    taskTitle,
			Updated: formatUnixTime(updatedAt),
		}
		// Parse window/pane indices from pane_id (e.g. "2.1" or safe name ending in W_P)
		if dot := strings.LastIndexByte(paneID, '.'); dot >= 0 {
			ps.WindowIdx, _ = strconv.Atoi(paneID[:dot])
			ps.PaneIdx, _ = strconv.Atoi(paneID[dot+1:])
		} else {
			// Safe name format — extract last two underscore-separated numbers
			parts := strings.Split(paneID, "_")
			if len(parts) >= 2 {
				ps.WindowIdx, _ = strconv.Atoi(parts[len(parts)-2])
				ps.PaneIdx, _ = strconv.Atoi(parts[len(parts)-1])
			}
		}
		statuses[paneID] = ps
	}
	return statuses
}

// readMessages reads all messages from the store, newest first.
func (sr *storeReader) readMessages() []Message {
	rows, err := sr.s.DB().Query(
		`SELECT id, from_pane, to_pane, subject, body, created_at FROM messages ORDER BY created_at DESC`,
	)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var msgs []Message
	for rows.Next() {
		var id int64
		var from, to, subject, body string
		var createdAt int64
		if err := rows.Scan(&id, &from, &to, &subject, &body, &createdAt); err != nil {
			continue
		}
		msgs = append(msgs, Message{
			ID:        fmt.Sprintf("%d", id),
			From:      from,
			To:        to,
			ToRaw:     to,
			Subject:   subject,
			Body:      body,
			Timestamp: createdAt,
		})
	}
	return msgs
}

// readTeams converts store teams to runtime TeamConfigs keyed by window index.
func (sr *storeReader) readTeams() map[int]TeamConfig {
	storeTeams, err := sr.s.ListTeams()
	if err != nil {
		return nil
	}
	teams := make(map[int]TeamConfig, len(storeTeams))
	for _, st := range storeTeams {
		winIdx, err := strconv.Atoi(st.WindowID)
		if err != nil {
			continue
		}
		teams[winIdx] = TeamConfig{
			WindowIndex: winIdx,
			TeamName:    st.Name,
			TeamType:    st.Type,
			WorktreeDir: st.WorktreePath,
			WorkerCount: st.PaneCount,
		}
	}
	return teams
}

// readAgents converts store agents to runtime AgentDefs.
//
// The store schema does not carry Color/Memory — those live only in the agent
// .md frontmatter. We parse each file on read so every row in the TUI renders
// with its declared color. This is cheap: there are typically <50 agents and
// snapshots aren't built on every frame.
func (sr *storeReader) readAgents() []AgentDef {
	storeAgents, err := sr.s.ListAgents()
	if err != nil {
		return nil
	}
	agents := make([]AgentDef, 0, len(storeAgents))
	for _, sa := range storeAgents {
		def := AgentDef{
			Name:        sa.Name,
			Description: sa.Description,
			Model:       sa.Model,
			FilePath:    sa.FilePath,
			Domain:      agentDomain(sa.Name),
		}
		if sa.FilePath != "" {
			if fm := parseFrontmatter(sa.FilePath); fm != nil {
				def.Color = fm["color"]
				def.Memory = fm["memory"]
				if def.Description == "" {
					def.Description = fm["description"]
				}
				if def.Model == "" {
					def.Model = fm["model"]
				}
			}
		}
		agents = append(agents, def)
	}
	return agents
}

// splitTags splits a comma-separated tag string into a slice, trimming whitespace.
func splitTags(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	tags := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p != "" {
			tags = append(tags, p)
		}
	}
	return tags
}

// formatUnixTime converts a unix epoch to an ISO 8601 string.
func formatUnixTime(epoch int64) string {
	if epoch == 0 {
		return ""
	}
	return time.Unix(epoch, 0).Format(time.RFC3339)
}
