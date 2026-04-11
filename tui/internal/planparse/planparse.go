// Package planparse parses Doey masterplan markdown into a structured Plan.
//
// # Canonical Plan Format
//
// A Doey plan is a markdown file with the following structure. The parser is
// intentionally lenient: missing sections are tolerated (partial writes during
// streaming are the common case). Sections are identified by H2 headers and
// phases are H3 headers inside `## Phases`.
//
//	# Plan: <title>
//
//	## Goal
//	<one or two sentences describing the objective>
//
//	## Context
//	<background, constraints, interview findings>
//
//	## Phases
//
//	### Phase 1: <name>
//	**Status:** in-progress
//	- [x] Completed step
//	- [ ] Pending step
//
//	### Phase 2: <name>
//	**Status:** planned
//	- [ ] Step A
//	- [ ] Step B
//
//	## Deliverables
//	- Deliverable one
//
//	## Risks
//	- Risk one
//
//	## Success Criteria
//	- Criterion one
//
// Accepted phase status values: planned (alias: pending), in-progress,
// done, failed. Phase status may also be conveyed by a leading emoji in the
// H3 title (⏳ planned, 🔄 in-progress, ✅ done, ❌ failed). Steps are parsed
// from GitHub-style checkbox bullets: "- [ ]" or "- [x]".
package planparse

import (
	"bufio"
	"bytes"
	"regexp"
	"strings"
)

// PhaseStatus represents the execution state of a Phase.
type PhaseStatus int

const (
	StatusPlanned PhaseStatus = iota
	StatusInProgress
	StatusDone
	StatusFailed
)

// String returns the canonical lowercase label for a PhaseStatus.
func (s PhaseStatus) String() string {
	switch s {
	case StatusInProgress:
		return "in-progress"
	case StatusDone:
		return "done"
	case StatusFailed:
		return "failed"
	default:
		return "planned"
	}
}

// Step is a single checkbox / sub-task inside a Phase.
type Step struct {
	Title string
	Done  bool
}

// Phase is a top-level implementation phase inside the plan.
type Phase struct {
	Title  string
	Status PhaseStatus
	Steps  []Step
	Body   string // extra markdown prose between the heading and the steps
}

// Plan is the parsed masterplan document.
type Plan struct {
	Title           string
	Goal            string
	Context         string
	Phases          []Phase
	Deliverables    []string
	Risks           []string
	SuccessCriteria []string
	Raw             string // original markdown — always populated
}

// HasStructure reports whether the parsed plan carries any structured
// content that the viewer can render beyond raw markdown.
func (p *Plan) HasStructure() bool {
	if p == nil {
		return false
	}
	return p.Title != "" || p.Goal != "" || len(p.Phases) > 0 ||
		len(p.Deliverables) > 0 || len(p.Risks) > 0 || len(p.SuccessCriteria) > 0
}

var (
	checkboxRe   = regexp.MustCompile(`^\s*[-*]\s*\[([ xX])\]\s*(.*)$`)
	bulletRe     = regexp.MustCompile(`^\s*[-*]\s+(.*)$`)
	statusLineRe = regexp.MustCompile(`(?i)^\s*\*\*\s*status\s*:?\s*\*\*\s*:?\s*(.+?)\s*$`)
	phaseTitleRe = regexp.MustCompile(`^###\s+(.*)$`)
	h1Re         = regexp.MustCompile(`^#\s+(.*)$`)
	h2Re         = regexp.MustCompile(`^##\s+(.*)$`)
	whitespaceRe = regexp.MustCompile(`\s+`)
)

var emojiStatuses = map[string]PhaseStatus{
	"⏳": StatusPlanned,
	"🔄": StatusInProgress,
	"✅": StatusDone,
	"✓": StatusDone,
	"❌": StatusFailed,
	"✗": StatusFailed,
}

// Parse returns a Plan for the given markdown bytes. The parser is lenient:
// unknown sections are ignored, missing sections yield zero values, and
// truncated/in-progress documents parse as much as is available. The Raw
// field is always populated with the input.
func Parse(content []byte) (*Plan, error) {
	p := &Plan{Raw: string(content)}

	scanner := bufio.NewScanner(bytes.NewReader(content))
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)

	var (
		currentH2    string
		normalizedH2 string
		sectionBuf   []string
		currentPhase *Phase
	)

	flushSection := func() {
		if currentH2 == "" {
			sectionBuf = nil
			return
		}
		assignSection(p, currentH2, sectionBuf)
		sectionBuf = nil
	}

	finishPhase := func() {
		if currentPhase != nil {
			currentPhase.Body = strings.TrimSpace(currentPhase.Body)
			p.Phases = append(p.Phases, *currentPhase)
			currentPhase = nil
		}
	}

	for scanner.Scan() {
		line := scanner.Text()

		if m := h1Re.FindStringSubmatch(line); m != nil && p.Title == "" {
			title := strings.TrimSpace(m[1])
			if lower := strings.ToLower(title); strings.HasPrefix(lower, "plan:") {
				title = strings.TrimSpace(title[len("plan:"):])
			}
			p.Title = title
			continue
		}

		if m := h2Re.FindStringSubmatch(line); m != nil {
			finishPhase()
			flushSection()
			currentH2 = strings.TrimSpace(m[1])
			normalizedH2 = normalizeHeader(currentH2)
			continue
		}

		if normalizedH2 == "phases" {
			if m := phaseTitleRe.FindStringSubmatch(line); m != nil {
				finishPhase()
				title, status, haveStatus := parsePhaseTitle(strings.TrimSpace(m[1]))
				currentPhase = &Phase{Title: title}
				if haveStatus {
					currentPhase.Status = status
				}
				continue
			}
			if currentPhase != nil {
				handlePhaseLine(currentPhase, line)
			}
			continue
		}

		sectionBuf = append(sectionBuf, line)
	}

	finishPhase()
	flushSection()

	if err := scanner.Err(); err != nil {
		return p, err
	}

	return p, nil
}

func normalizeHeader(h string) string {
	h = strings.ToLower(strings.TrimSpace(h))
	h = strings.TrimSuffix(h, ":")
	switch h {
	case "goal", "objective":
		return "goal"
	case "context", "background":
		return "context"
	case "phases", "approach", "steps", "plan":
		return "phases"
	case "risks", "risks & mitigations", "risks and mitigations":
		return "risks"
	case "deliverables", "artifacts":
		return "deliverables"
	case "success criteria", "success", "acceptance criteria":
		return "success criteria"
	}
	return h
}

func assignSection(p *Plan, header string, lines []string) {
	key := normalizeHeader(header)
	switch key {
	case "goal":
		p.Goal = trimBlock(lines)
	case "context":
		p.Context = trimBlock(lines)
	case "risks":
		p.Risks = extractBullets(lines)
	case "deliverables":
		p.Deliverables = extractBullets(lines)
	case "success criteria":
		p.SuccessCriteria = extractBullets(lines)
	}
}

func trimBlock(lines []string) string {
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func extractBullets(lines []string) []string {
	var items []string
	for _, l := range lines {
		if m := bulletRe.FindStringSubmatch(l); m != nil {
			text := strings.TrimSpace(m[1])
			if text != "" {
				items = append(items, text)
			}
		}
	}
	return items
}

func parsePhaseTitle(raw string) (title string, status PhaseStatus, haveStatus bool) {
	title = raw
	for emoji, s := range emojiStatuses {
		if strings.HasPrefix(title, emoji) {
			return strings.TrimSpace(strings.TrimPrefix(title, emoji)), s, true
		}
	}
	for emoji, s := range emojiStatuses {
		if strings.HasSuffix(title, emoji) {
			return strings.TrimSpace(strings.TrimSuffix(title, emoji)), s, true
		}
	}
	return title, StatusPlanned, false
}

func handlePhaseLine(phase *Phase, line string) {
	if m := checkboxRe.FindStringSubmatch(line); m != nil {
		done := m[1] == "x" || m[1] == "X"
		phase.Steps = append(phase.Steps, Step{Title: strings.TrimSpace(m[2]), Done: done})
		return
	}
	if m := statusLineRe.FindStringSubmatch(line); m != nil {
		phase.Status = canonicalStatus(m[1])
		return
	}
	trimmed := strings.TrimSpace(line)
	if trimmed == "" && phase.Body == "" {
		return
	}
	if phase.Body == "" {
		phase.Body = trimmed
	} else {
		phase.Body += "\n" + trimmed
	}
}

func canonicalStatus(s string) PhaseStatus {
	s = strings.ToLower(strings.TrimSpace(s))
	s = whitespaceRe.ReplaceAllString(s, " ")
	switch s {
	case "planned", "pending", "todo", "to do", "not started":
		return StatusPlanned
	case "in-progress", "in progress", "running", "active", "wip":
		return StatusInProgress
	case "done", "complete", "completed", "finished":
		return StatusDone
	case "failed", "error", "blocked":
		return StatusFailed
	}
	return StatusPlanned
}
