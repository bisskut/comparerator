# AI Branch Review Prompt

Review the attached branch-promotion package.

The package may contain:

- `review.md`
- `report-data.json`
- `commits.csv`
- `changed-files.csv`
- `project-activity.csv`
- `diff-stat.txt`
- `divergence.txt`
- `changes.patch`

## Review goals

Assess:

1. Functional regression risk
2. Database, configuration, dependency, deployment, and API risk
3. Incomplete or inconsistent changes
4. Application changes without adequate test changes
5. Interactions between changed files
6. Aging, stagnant, blocked, superseded, or possibly abandoned work
7. Areas that require specialist review
8. Expected repair or resurrection effort
9. Questions that should be resolved in the meeting
10. Appropriate scope for a larger technical audit

## Rules

For every finding:

- Cite the relevant file, commit, project/folder, or diff section.
- State whether it is confirmed or inferred.
- Assign severity: critical, high, medium, low, or informational.
- Describe the likely consequence.
- Estimate best-case, likely, and worst-case effort.
- State confidence in the estimate.
- Do not claim that the branches merge, compile, test, or deploy successfully unless evidence is included.
- Treat classifications such as “possibly abandoned” as signals requiring human confirmation, not proof.

## Finish with

- Executive summary
- Meeting discussion priorities
- Blocking concerns
- Aging or ownership concerns
- Recommended owners by subsystem
- Questions requiring human clarification
- Suggested scope for the larger audit
- Go/no-go recommendation, with confidence
