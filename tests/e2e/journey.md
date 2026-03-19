# E2E Journey: Build a Doey Marketing Website

Test driver sends a website-building task to the Window Manager and monitors the full team. Exercises delegation, parallel work, file creation, mid-journey interaction, and coordination.

## Initial Task Prompt

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

After initial pages are complete, send:

```
Great work! Two additions:
1. Add a footer to ALL pages with "Built with Doey" and a copyright year
2. Add a dark mode toggle button in the navigation bar — it should toggle a .dark-mode class on the body element, with appropriate CSS for both themes
```

## Expected Outcomes

### Files
- index.html (valid HTML5), features.html, how-it-works.html (or equivalent)
- styles.css (50+ lines), script.js
- At least 3 HTML files total

### Content
- index.html mentions "Claude" (case-insensitive)
- At least one page mentions "worker", "dispatch", or "Window Manager"
- CSS has color definitions (#00d2ff or similar)
- HTML files have `<nav>` and link to styles.css

### Behavior
- Manager delegated to workers (did NOT create files itself)
- At least 2 workers dispatched in parallel
- Watchdog showed scan activity
- No worker stuck on same error 3+ times
- Completed within 10 minutes

### After Mid-Journey
- "Built with Doey" footer in at least one HTML file
- Dark mode toggle button in nav/header
- CSS contains `.dark-mode` rules

## Anomaly Criteria

| Signal | Meaning |
|--------|---------|
| Manager pane shows Write/Edit calls | Manager coding directly (should delegate) |
| Worker shows "Permission denied" / "SIGTERM" | Crash |
| Manager pane unchanged 2+ min | Possible hang |
| Watchdog no timestamps for 60s+ | Watchdog stopped |
