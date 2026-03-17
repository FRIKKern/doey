# Skill: doey-remove-column

Remove a worker column from the dynamic grid.

## Usage
`/doey-remove-column [N]`

## Prompt
Remove a column of workers from the dynamic grid.

### Step 1: Remove column

If a column number N was specified as an argument:
```bash
doey remove N
```

Otherwise remove the last column:
```bash
doey remove
```

### Step 2: Report

Report the result — which column was removed and the new grid dimensions. If it failed (e.g., at minimum columns, or workers still busy), explain why.
