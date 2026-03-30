package setup

import (
	"fmt"
	"os"
	"strings"

	"github.com/charmbracelet/huh"
	"github.com/charmbracelet/lipgloss"
)

func buildPresetOptions() []huh.Option[string] {
	return []huh.Option[string]{
		huh.NewOption("Regular Setup — 2 regular teams (default)", "regular"),
		huh.NewOption("Reserved Freelancers + Regular Team — 1 freelancer pool (3×2) + 1 team", "freelancer_regular"),
		huh.NewOption("Custom Combination — mix and match teams", "custom"),
	}
}

func buildCustomOptions() []huh.Option[string] {
	options := []huh.Option[string]{
		huh.NewOption("Regular Team (4 workers)", "regular"),
		huh.NewOption("Reserved Freelancers (3×2 grid, born reserved)", "freelancer"),
	}

	if cwd, err := os.Getwd(); err == nil {
		for _, d := range DiscoverTeamDefs(cwd) {
			label := fmt.Sprintf("Premade: %s", d.Name)
			options = append(options, huh.NewOption(label, "premade:"+d.Def))
		}
	}

	return options
}

func buildTeamsFromCustom(selections []string) []TeamEntry {
	var teams []TeamEntry
	for i, t := range selections {
		switch {
		case t == "regular":
			teams = append(teams, TeamEntry{
				Type:    "regular",
				Name:    fmt.Sprintf("Team %d", i+1),
				Workers: 4,
			})
		case t == "freelancer":
			teams = append(teams, TeamEntry{
				Type:    "freelancer",
				Name:    "Reserved Freelancers",
				Workers: 6,
			})
		case strings.HasPrefix(t, "premade:"):
			def := strings.TrimPrefix(t, "premade:")
			teams = append(teams, TeamEntry{
				Type: "premade",
				Name: def,
				Def:  def,
			})
		}
	}
	if len(teams) == 0 {
		teams = Presets["regular"]
	}
	return teams
}

func renderSummary(teams []TeamEntry) string {
	style := lipgloss.NewStyle().
		Border(lipgloss.RoundedBorder()).
		Padding(1, 2).
		BorderForeground(lipgloss.Color("99"))

	s := "Teams to create:\n\n"
	for i, t := range teams {
		icon := "◆"
		if t.Type == "freelancer" {
			icon = "•"
		}
		s += fmt.Sprintf("  %s %d. %s (%s, %d workers)\n", icon, i+1, t.Name, t.Type, t.Workers)
	}

	return style.Render(s)
}

// Run executes the wizard and returns the result.
// Uses huh.Form.Run() directly — no bubbletea. This ensures:
//   - No stdout pollution (huh renders to /dev/tty)
//   - No value-semantics binding bugs (synchronous execution)
func Run() (SetupResult, error) {
	titleStyle := lipgloss.NewStyle().
		Bold(true).
		Foreground(lipgloss.Color("99")).
		MarginBottom(1)

	for {
		// Step 1: Preset selection
		fmt.Fprintln(os.Stderr, titleStyle.Render("◆ Doey Setup Wizard"))

		var presetChoice string
		err := huh.NewForm(
			huh.NewGroup(
				huh.NewSelect[string]().
					Title("Choose a setup:").
					Options(buildPresetOptions()...).
					Value(&presetChoice),
			),
		).WithTheme(huh.ThemeCharm()).Run()
		if err != nil {
			return SetupResult{Cancelled: true}, nil
		}

		var teams []TeamEntry

		switch presetChoice {
		case "regular":
			teams = Presets["regular"]
		case "freelancer_regular":
			teams = Presets["freelancer_regular"]
		case "custom":
			// Step 2: Custom team selection
			var customTypes []string
			err := huh.NewForm(
				huh.NewGroup(
					huh.NewMultiSelect[string]().
						Title("Select team types to add:").
						Options(buildCustomOptions()...).
						Value(&customTypes),
				),
			).WithTheme(huh.ThemeCharm()).Run()
			if err != nil {
				return SetupResult{Cancelled: true}, nil
			}
			teams = buildTeamsFromCustom(customTypes)
		default:
			continue
		}

		// Step 3: Summary + confirm/back
		fmt.Fprintln(os.Stderr, titleStyle.Render("◆ Doey Setup Wizard"))
		fmt.Fprintln(os.Stderr, renderSummary(teams))

		var confirmed bool
		err = huh.NewForm(
			huh.NewGroup(
				huh.NewConfirm().
					Title("Launch with this configuration?").
					Affirmative("Launch").
					Negative("Go back").
					Value(&confirmed),
			),
		).WithTheme(huh.ThemeCharm()).Run()
		if err != nil {
			return SetupResult{Cancelled: true}, nil
		}

		if confirmed {
			return SetupResult{Teams: teams}, nil
		}
		// Not confirmed — loop back to preset selection
	}
}
