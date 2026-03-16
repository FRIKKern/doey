# E2E Journey: Build a Doey Marketing Website

## Overview

The test driver sends a realistic website-building task to the Window Manager and monitors the full team (Window Manager, Watchdog, Workers) as they collaborate to build a multi-page marketing website about Doey. This exercises delegation, parallel work, file creation, mid-journey interaction, and end-to-end coordination.

## Initial Task Prompt

The exact text to send to the Window Manager:

```
Build a marketing website for "Doey" — the tmux-based multi-agent orchestration system for Claude Code.

Requirements:
1. Multi-page site with at least: index.html, features.html, how-it-works.html
2. A shared CSS file (styles.css) with a modern, clean design
3. A shared JavaScript file (script.js) for mobile nav toggle and smooth scrolling
4. Navigation bar on all pages linking to each page
5. Content should cover:
   - Hero section: what Doey is and why it matters
   - Features: Window Manager orchestration, parallel workers, Watchdog monitoring, slash commands
   - How it works: tmux grid layout, task dispatch, status monitoring, worker lifecycle
   - Get Started: installation steps (git clone, ./install.sh, cd project, doey)
6. Responsive design (mobile-friendly)
7. Professional color scheme: dark backgrounds (#1a1a2e, #16213e), cyan accents (#00d2ff), white text
8. Clean typography using system fonts

All files must be created in the project directory using absolute paths.
Make it look polished — this is a real marketing site.
```

## Mid-Journey Interaction

After the Window Manager reports initial pages are complete (or asks if anything else is needed), send:

```
Great work! Two additions:
1. Add a footer to ALL pages with "Built with Doey" and a copyright year
2. Add a dark mode toggle button in the navigation bar — it should toggle a .dark-mode class on the body element, with appropriate CSS for both themes
```

## Expected Outcomes

### File Checks

- index.html exists and is valid HTML5
- features.html exists
- how-it-works.html exists (or equivalent like docs.html, getting-started.html)
- styles.css exists with actual CSS rules (at least 50 lines)
- script.js exists
- At least 3 HTML files total

### Content Checks

- index.html contains "Claude" (case-insensitive)
- At least one page mentions "worker" or "dispatch" or "Window Manager"
- CSS contains color definitions (#00d2ff or similar)
- HTML files contain `<nav>` element
- HTML files link to styles.css

### Behavioral Checks

- Window Manager delegated to workers (did NOT create files itself)
- At least 2 workers were dispatched in parallel
- Watchdog pane showed scan activity
- No worker stuck on same error 3+ times
- Window Manager didn't crash
- Completed within 10 minutes

### After Mid-Journey

- Footer text "Built with Doey" appears in at least one HTML file
- Dark mode toggle: a button element in nav/header
- CSS contains .dark-mode rules

## Anomaly Criteria

- Window Manager pane shows Write/Edit tool calls -> Window Manager is coding directly (SHOULD delegate)
- Worker shows "Permission denied" or "SIGTERM" -> crash
- Window Manager pane unchanged for 2+ minutes -> possible hang
- Watchdog pane shows no timestamps for 60s+ -> watchdog stopped
