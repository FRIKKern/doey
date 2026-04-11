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
	"fmt"
	"os"
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
// content that the viewer can render beyond raw markdown. A title alone
// is not enough — the structured renderer would drop the body. Require
// at least one real section (goal, context, phases, deliverables,
// risks, success criteria) before returning true.
func (p *Plan) HasStructure() bool {
	if p == nil {
		return false
	}
	return p.Goal != "" || p.Context != "" || len(p.Phases) > 0 ||
		len(p.Deliverables) > 0 || len(p.Risks) > 0 || len(p.SuccessCriteria) > 0
}

var (
	checkboxRe    = regexp.MustCompile(`^\s*[-*]\s*\[([ xX])\]\s*(.*)$`)
	bulletRe      = regexp.MustCompile(`^\s*[-*]\s+(.*)$`)
	statusLineRe  = regexp.MustCompile(`(?i)^\s*\*\*\s*status\s*:?\s*\*\*\s*:?\s*(.+?)\s*$`)
	phaseTitleRe  = regexp.MustCompile(`^###\s+(.*)$`)
	h1Re          = regexp.MustCompile(`^#\s+(.*)$`)
	h2Re          = regexp.MustCompile(`^##\s+(.*)$`)
	whitespaceRe  = regexp.MustCompile(`\s+`)
	phasePrefixRe = regexp.MustCompile(`(?i)^phase\s*\d+\s*[:\-–—]\s*`)
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
			stripped := strings.TrimSpace(strings.TrimPrefix(title, emoji))
			return stripPhasePrefix(stripped), s, true
		}
	}
	for emoji, s := range emojiStatuses {
		if strings.HasSuffix(title, emoji) {
			stripped := strings.TrimSpace(strings.TrimSuffix(title, emoji))
			return stripPhasePrefix(stripped), s, true
		}
	}
	return stripPhasePrefix(title), StatusPlanned, false
}

// stripPhasePrefix removes a leading "Phase N:" marker from a phase
// title so renderers that prepend their own "Phase N —" don't emit a
// duplicated prefix.
func stripPhasePrefix(title string) string {
	return strings.TrimSpace(phasePrefixRe.ReplaceAllString(title, ""))
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

// Marshal serializes the Plan as canonical masterplan markdown. Output
// is deterministic (stable phase order, no map iteration) and re-parses
// to an equal Plan — modulo the Raw field, which always reflects the
// bytes passed to a given Parse call. Sections that are zero-valued in
// the source are omitted so round-tripping does not invent structure
// the original lacked.
func (p *Plan) Marshal() ([]byte, error) {
	if p == nil {
		return []byte{}, nil
	}
	var buf bytes.Buffer
	if p.Title != "" {
		fmt.Fprintf(&buf, "# Plan: %s\n", p.Title)
	}
	if p.Goal != "" {
		buf.WriteString("\n## Goal\n")
		buf.WriteString(p.Goal)
		buf.WriteString("\n")
	}
	if p.Context != "" {
		buf.WriteString("\n## Context\n")
		buf.WriteString(p.Context)
		buf.WriteString("\n")
	}
	if len(p.Phases) > 0 {
		buf.WriteString("\n## Phases\n")
		for i, ph := range p.Phases {
			fmt.Fprintf(&buf, "\n### Phase %d: %s\n", i+1, ph.Title)
			fmt.Fprintf(&buf, "**Status:** %s\n", ph.Status.String())
			if ph.Body != "" {
				buf.WriteString(ph.Body)
				buf.WriteString("\n")
			}
			for _, s := range ph.Steps {
				mark := " "
				if s.Done {
					mark = "x"
				}
				fmt.Fprintf(&buf, "- [%s] %s\n", mark, s.Title)
			}
		}
	}
	if len(p.Deliverables) > 0 {
		buf.WriteString("\n## Deliverables\n")
		for _, d := range p.Deliverables {
			fmt.Fprintf(&buf, "- %s\n", d)
		}
	}
	if len(p.Risks) > 0 {
		buf.WriteString("\n## Risks\n")
		for _, r := range p.Risks {
			fmt.Fprintf(&buf, "- %s\n", r)
		}
	}
	if len(p.SuccessCriteria) > 0 {
		buf.WriteString("\n## Success Criteria\n")
		for _, s := range p.SuccessCriteria {
			fmt.Fprintf(&buf, "- %s\n", s)
		}
	}
	return buf.Bytes(), nil
}

// WriteFile writes the Marshal output to path atomically: bytes go to
// a sibling "<path>.tmp" file first and then rename into place so a
// concurrent reader never observes a partial write.
func (p *Plan) WriteFile(path string) error {
	data, err := p.Marshal()
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return nil
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
