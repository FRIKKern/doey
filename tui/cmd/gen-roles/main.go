// gen-roles reads shell/doey-roles.sh and generates tui/internal/roles/roles_gen.go.
//
// It is invoked via go generate from the tui/internal/roles/ directory.
package main

import (
	"bufio"
	"fmt"
	"os"
	"regexp"
	"strings"
)

// roleDef holds a parsed shell variable assignment.
type roleDef struct {
	goName string // Go constant name, e.g. "Coordinator"
	value  string // quoted value, e.g. "Taskmaster"
}

// shellKeyToGo maps the SCREAMING_SNAKE suffix to a PascalCase Go name.
var shellKeyToGo = map[string]string{
	"COORDINATOR": "Coordinator",
	"TEAM_LEAD":   "TeamLead",
	"BOSS":        "Boss",
	"WORKER":      "Worker",
	"FREELANCER":  "Freelancer",
	"INFO_PANEL":    "InfoPanel",
	"TEST_DRIVER":   "TestDriver",
	"TASK_REVIEWER": "TaskReviewer",
	"DEPLOYMENT":    "Deployment",
	"DOEY_EXPERT":   "DoeyExpert",
}

// Ordered keys so output is deterministic.
var keyOrder = []string{
	"COORDINATOR",
	"TEAM_LEAD",
	"BOSS",
	"WORKER",
	"FREELANCER",
	"INFO_PANEL",
	"TEST_DRIVER",
	"TASK_REVIEWER",
	"DEPLOYMENT",
	"DOEY_EXPERT",
}

func main() {
	// go generate runs from tui/internal/roles/
	const shellPath = "../../../shell/doey-roles.sh"

	f, err := os.Open(shellPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "gen-roles: %v\n", err)
		os.Exit(1)
	}
	defer f.Close()

	// Parse all DOEY_ROLE_*="value" lines.
	re := regexp.MustCompile(`^DOEY_ROLE_(\w+)="([^"]*)"$`)

	display := map[string]string{} // suffix → value  (DOEY_ROLE_X)
	ids := map[string]string{}     // suffix → value  (DOEY_ROLE_ID_X)
	files := map[string]string{}   // suffix → value  (DOEY_ROLE_FILE_X)

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		m := re.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		key, val := m[1], m[2]

		switch {
		case strings.HasPrefix(key, "ID_"):
			suffix := strings.TrimPrefix(key, "ID_")
			ids[suffix] = val
		case strings.HasPrefix(key, "FILE_"):
			suffix := strings.TrimPrefix(key, "FILE_")
			files[suffix] = val
		default:
			display[key] = val
		}
	}
	if err := scanner.Err(); err != nil {
		fmt.Fprintf(os.Stderr, "gen-roles: reading %s: %v\n", shellPath, err)
		os.Exit(1)
	}

	// Build output.
	var b strings.Builder
	b.WriteString("// Code generated from shell/doey-roles.sh; DO NOT EDIT.\n\npackage roles\n")

	writeBlock := func(comment, prefix string, data map[string]string) {
		b.WriteString("\n// " + comment + "\nconst (\n")
		for _, suffix := range keyOrder {
			val, ok := data[suffix]
			if !ok {
				continue
			}
			goName := prefix + shellKeyToGo[suffix]
			b.WriteString(fmt.Sprintf("\t%s = %q\n", goName, val))
		}
		b.WriteString(")\n")
	}

	writeBlock("Display names (user-facing)", "", display)
	writeBlock("Internal IDs (stable, used in status files and logic)", "ID", ids)
	writeBlock("File naming patterns (agent files, skill dirs)", "File", files)

	if err := os.WriteFile("roles_gen.go", []byte(b.String()), 0o644); err != nil {
		fmt.Fprintf(os.Stderr, "gen-roles: writing roles_gen.go: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("gen-roles: wrote roles_gen.go")
}
