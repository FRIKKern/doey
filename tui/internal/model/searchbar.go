package model

import (
	"errors"
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/search"
	"github.com/doey-cli/doey/tui/internal/store"
	"github.com/doey-cli/doey/tui/internal/styles"
)

const (
	taskSearchDebounce = 150 * time.Millisecond
	taskSearchLimit    = 50
)

// TaskSearchTickMsg fires after the debounce window. The TasksModel runs the
// FTS query only when Gen still matches the latest keystroke generation.
type TaskSearchTickMsg struct{ Gen int }

// TaskSearchResultsMsg delivers FTS results back to the search bar.
type TaskSearchResultsMsg struct {
	Gen     int
	Query   string
	Results []search.SearchResult
	Err     error
}

// taskSearchBar is the vim-style `/` search overlay for the task list pane.
// Active only when the task list is focused and `/` was pressed; Esc clears.
type taskSearchBar struct {
	active bool
	query  string
	cursor int // selected result index
	gen    int // increments per keystroke; debounce drops stale ticks
	last   string
	res    []search.SearchResult
	err    error
}

// Active reports whether search mode is currently capturing keys.
func (s taskSearchBar) Active() bool { return s.active }

// Open enters search mode with an empty query.
func (s *taskSearchBar) Open() {
	s.active = true
	s.query = ""
	s.cursor = 0
	s.last = ""
	s.res = nil
	s.err = nil
}

// Close exits search mode and clears state.
func (s *taskSearchBar) Close() {
	s.active = false
	s.query = ""
	s.cursor = 0
	s.last = ""
	s.res = nil
	s.err = nil
}

// SelectedTaskID returns the task ID under the cursor as a string,
// or "" when no result is selected.
func (s taskSearchBar) SelectedTaskID() string {
	if !s.active || len(s.res) == 0 {
		return ""
	}
	if s.cursor < 0 || s.cursor >= len(s.res) {
		return ""
	}
	return strconv.FormatInt(s.res[s.cursor].TaskID, 10)
}

// HandleKey processes a key event in search mode. Returns the updated bar,
// any tea.Cmd to dispatch, and consumed=true when the bar swallowed the key.
// The Enter case is consumed but the caller is responsible for opening the
// selected task — read SelectedTaskID() afterwards.
func (s taskSearchBar) HandleKey(msg tea.KeyMsg, dbPath string) (taskSearchBar, tea.Cmd, bool) {
	if !s.active {
		return s, nil, false
	}
	switch msg.Type {
	case tea.KeyEsc:
		s.Close()
		return s, nil, true
	case tea.KeyEnter:
		// Consumed; caller reads SelectedTaskID() to navigate.
		return s, nil, true
	case tea.KeyUp:
		if s.cursor > 0 {
			s.cursor--
		}
		return s, nil, true
	case tea.KeyDown:
		if s.cursor < len(s.res)-1 {
			s.cursor++
		}
		return s, nil, true
	case tea.KeyBackspace:
		if len(s.query) > 0 {
			s.query = s.query[:len(s.query)-1]
			return s, s.scheduleQuery(), true
		}
		return s, nil, true
	case tea.KeyRunes:
		s.query += string(msg.Runes)
		return s, s.scheduleQuery(), true
	case tea.KeySpace:
		s.query += " "
		return s, s.scheduleQuery(), true
	}
	if msg.String() == "ctrl+u" {
		s.query = ""
		s.res = nil
		s.last = ""
		s.cursor = 0
		return s, nil, true
	}
	// Consume all other keys while search mode is active so they don't
	// silently fall through to list nav (acceptance criteria from plan 1011).
	return s, nil, true
}

// scheduleQuery bumps the generation counter and returns a debounced tick.
// The tick fires after taskSearchDebounce; the model only runs the query
// when the tick's Gen still matches s.gen.
func (s *taskSearchBar) scheduleQuery() tea.Cmd {
	s.gen++
	g := s.gen
	return tea.Tick(taskSearchDebounce, func(time.Time) tea.Msg {
		return TaskSearchTickMsg{Gen: g}
	})
}

// HandleTick runs the FTS query if msg.Gen still matches the current gen
// (no newer keystroke has arrived).
func (s taskSearchBar) HandleTick(msg TaskSearchTickMsg, dbPath string) (taskSearchBar, tea.Cmd) {
	if !s.active {
		return s, nil
	}
	if msg.Gen != s.gen {
		return s, nil
	}
	q := strings.TrimSpace(s.query)
	if q == "" {
		s.res = nil
		s.last = ""
		return s, nil
	}
	if q == s.last {
		return s, nil
	}
	s.last = q
	return s, runTaskSearchCmd(dbPath, q, s.gen)
}

// HandleResults applies query results when the gen still matches.
func (s taskSearchBar) HandleResults(msg TaskSearchResultsMsg) taskSearchBar {
	if !s.active {
		return s
	}
	if msg.Gen != s.gen {
		return s
	}
	s.res = msg.Results
	s.err = msg.Err
	if s.cursor >= len(s.res) {
		s.cursor = 0
	}
	return s
}

// runTaskSearchCmd opens the project DB, runs FTS5, and returns a result msg.
// Multi-word queries are tokenised into prefix-matched quoted terms so a
// user typing "auth tok" matches "authentication token".
func runTaskSearchCmd(dbPath, query string, gen int) tea.Cmd {
	return func() tea.Msg {
		if dbPath == "" {
			return TaskSearchResultsMsg{Gen: gen, Query: query, Err: errors.New("no project DB")}
		}
		s, err := store.Open(dbPath)
		if err != nil {
			return TaskSearchResultsMsg{Gen: gen, Query: query, Err: err}
		}
		defer s.Close()
		ftsQuery := buildFTSQuery(query)
		results, err := search.TextSearch(s.DB(), search.TextSearchOpts{
			Query: ftsQuery,
			Limit: taskSearchLimit,
		})
		return TaskSearchResultsMsg{Gen: gen, Query: query, Results: results, Err: err}
	}
}

// buildFTSQuery wraps each whitespace-separated term in a quoted FTS5 phrase
// with a trailing prefix `*`. Embedded double-quotes are doubled per FTS5
// spec. An empty input yields a no-match query.
func buildFTSQuery(raw string) string {
	words := strings.Fields(raw)
	if len(words) == 0 {
		return ""
	}
	parts := make([]string, 0, len(words))
	for _, w := range words {
		w = strings.ReplaceAll(w, `"`, `""`)
		parts = append(parts, fmt.Sprintf(`"%s"*`, w))
	}
	return strings.Join(parts, " ")
}

// dbPathFor returns the SQLite path for the given project directory, or ""
// when projectDir is unset.
func dbPathFor(projectDir string) string {
	if projectDir == "" {
		return ""
	}
	return filepath.Join(projectDir, ".doey", "doey.db")
}

// View renders the single-line input bar plus a match-count summary. Suitable
// for placement at the top of the task list pane.
func (s taskSearchBar) View(theme styles.Theme, width int) string {
	if !s.active {
		return ""
	}
	prompt := lipgloss.NewStyle().Bold(true).Foreground(theme.Primary).Render("/")
	input := lipgloss.NewStyle().Foreground(theme.Text).Render(s.query + "█")

	var note string
	switch {
	case s.err != nil:
		note = lipgloss.NewStyle().Foreground(theme.Danger).Render("error: " + s.err.Error())
	case strings.TrimSpace(s.query) == "":
		note = lipgloss.NewStyle().Foreground(theme.Muted).Faint(true).Render("type to search")
	case len(s.res) == 0:
		note = lipgloss.NewStyle().Foreground(theme.Muted).Faint(true).Render("0 matches")
	case len(s.res) == 1:
		note = lipgloss.NewStyle().Foreground(theme.Muted).Faint(true).Render("1 match")
	default:
		note = lipgloss.NewStyle().Foreground(theme.Muted).Faint(true).Render(fmt.Sprintf("%d matches", len(s.res)))
	}
	line := prompt + input + "  " + note
	return lipgloss.NewStyle().Width(width).PaddingLeft(1).Render(line)
}

// RenderResults renders the result list with snippets, highlighting the
// cursor row. Returns "" when there's nothing useful to render.
func (s taskSearchBar) RenderResults(theme styles.Theme, width, maxLines int) string {
	if !s.active {
		return ""
	}
	if len(s.res) == 0 {
		if strings.TrimSpace(s.query) != "" && s.err == nil {
			return lipgloss.NewStyle().Foreground(theme.Muted).Faint(true).PaddingLeft(2).
				Render("(no matches)")
		}
		return ""
	}
	cleaner := strings.NewReplacer("<b>", "", "</b>", "")
	var lines []string
	rowsBudget := maxLines
	if rowsBudget < 2 {
		rowsBudget = 2
	}
	for i, r := range s.res {
		if len(lines) >= rowsBudget {
			break
		}
		title := r.Title
		if title == "" {
			title = "(no title)"
		}
		head := fmt.Sprintf("#%d  %s", r.TaskID, title)
		body := strings.TrimSpace(cleaner.Replace(r.Snippet))
		if i == s.cursor {
			head = lipgloss.NewStyle().Bold(true).Foreground(theme.Primary).Render("▶ " + head)
			if body != "" {
				body = lipgloss.NewStyle().Foreground(theme.Text).PaddingLeft(2).Render(body)
			}
		} else {
			head = lipgloss.NewStyle().Foreground(theme.Text).Render("  " + head)
			if body != "" {
				body = lipgloss.NewStyle().Foreground(theme.Muted).PaddingLeft(2).Render(body)
			}
		}
		lines = append(lines, head)
		if body != "" && len(lines) < rowsBudget {
			lines = append(lines, body)
		}
	}
	if len(s.res) > rowsBudget/2 && len(lines) >= rowsBudget {
		more := len(s.res) - (rowsBudget / 2)
		if more > 0 {
			lines = append(lines, lipgloss.NewStyle().Foreground(theme.Muted).Faint(true).
				PaddingLeft(2).Render(fmt.Sprintf("… %d more", more)))
		}
	}
	return lipgloss.NewStyle().Width(width).Render(strings.Join(lines, "\n"))
}
