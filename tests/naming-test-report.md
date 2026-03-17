# Tmux Pane Naming Convention Report

## Raw Pane Listing

```
0 ⠂ doey-manager
1 ⠐ naming-report_0317
2 W2 T1
3 W3 T1
4 W4 T1
5 W5 T1
6 W6 T1
```

## Window Manager Pane Verification

Pane 0 has the title `⠂ doey-manager`. This does **not** match the expected pattern of "T1 Window Manager". Instead, it uses the format `doey-manager` prefixed with a Braille dot spinner character (`⠂`), which appears to be a status/activity indicator. The title identifies the role but does not include the team number prefix.

## Naming Convention Description

The panes follow two distinct naming patterns:

- **Window Manager (pane 0):** Uses the format `<spinner> doey-manager`, where the spinner is a Braille pattern character indicating activity state.
- **Workers (panes 1–6):** Use the format `W<N> T<W>`, where `W<N>` is the worker number (sequential across the pane index) and `T<W>` is the team/window number. For example, `W2 T1` means Worker 2 in Team 1.
- **Exception — pane 1 (this worker):** Currently titled `naming-report_0317` due to the `/rename` command being run at the start of this task. Its default title would follow the `W1 T1` pattern.

The spinner prefixes (`⠂`, `⠐`) on panes 0 and 1 appear to be activity/status indicators (idle vs. busy).
