# Pane Naming Convention

## Pane Listing

```
0 ⠂ doey-manager
1 ⠐ naming-report_0317
2 W2 T1
3 W3 T1
4 W4 T1
5 W5 T1
6 W6 T1
```

## Naming Patterns

- **Manager (pane 0):** `<spinner> doey-manager` — Braille spinner indicates activity state.
- **Workers (panes 1–6):** `W<N> T<W>` — worker number + team number (e.g. `W2 T1` = Worker 2, Team 1).
- Spinner prefixes (`⠂`/`⠐`) are idle/busy indicators.
- Pane 1 shows `naming-report_0317` due to `/rename` — default would be `W1 T1`.
