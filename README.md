# Branch Review Toolkit

This toolkit generates a first-meeting review packet for comparing:

- `dev → qa`
- `qa → uat`
- `uat → prod`
- `dev → prod` end-to-end drift

It also detects aging and potentially stagnant work by project/folder.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Git available on `PATH`
- Run from inside the Git repository
- Remote branches should normally exist under `origin`

## Files

- `Generate-BranchReview.ps1` — report generator
- `AI-Review-Prompt.md` — reusable prompt for AI analysis

## Typical run

```powershell
Set-ExecutionPolicy -Scope Process Bypass

.\Generate-BranchReview.ps1 `
    -Branches dev,qa,uat,prod `
    -Remote origin `
    -OutputDirectory .\branch-review
```

## Two-branch run

```powershell
.\Generate-BranchReview.ps1 `
    -Branches dev,main `
    -OutputDirectory .\branch-review
```

## Useful options

```powershell
-FolderDepth 2
```

Controls how paths are grouped into project/folder areas.

Examples:

- `1` groups by `src`, `tests`, `docs`
- `2` groups by `src/Orders`, `src/Billing`
- `3` groups more narrowly

```powershell
-ActiveDays 30
-IntermittentDays 90
-AgingDays 180
```

Controls the activity classifications.

```powershell
-SkipFetch
```

Skips `git fetch origin --prune`.

## Output

```text
branch-review/
├── executive-summary.md
├── branch-data.json
├── dev-to-qa/
│   ├── review.md
│   ├── report-data.json
│   ├── commits.csv
│   ├── changed-files.csv
│   ├── project-activity.csv
│   ├── diff-stat.txt
│   ├── divergence.txt
│   └── changes.patch
├── qa-to-uat/
├── uat-to-prod/
└── dev-to-prod/
```

## Classification meanings

- **Active development**: newest unique change is within the active threshold.
- **Intermittent development**: work is older but still relatively recent.
- **Aging unpromoted work**: unique changes are old enough to require ownership review.
- **Possibly abandoned**: no unique change inside the aging threshold and no contradictory recent activity.
- **Historical branch drift**: old differences exist, but the source project still has activity or the difference may be intentional/superseded.

These are review signals, not final judgments.

## Recommended meeting use

1. Open `executive-summary.md`.
2. Review target-only commits.
3. Review aging and possibly abandoned project areas.
4. Confirm ownership and intent.
5. Review each pair’s `review.md`.
6. Feed the pair folder plus `AI-Review-Prompt.md` to an AI reviewer.
7. Use the meeting to define the larger build/test/synthetic-merge audit.
