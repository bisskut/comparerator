param(
    [string[]]$Branches = @("dev", "qa", "uat", "prod"),
    [string]$Remote = "origin",
    [string]$OutputDirectory = ".\branch-review",
    [int]$FolderDepth = 2,
    [int]$ActiveDays = 30,
    [int]$IntermittentDays = 90,
    [int]$AgingDays = 180,
    [switch]$SkipFetch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Git {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $output = & git @Arguments 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Git command failed: git $($Arguments -join ' ')`n$output"
    }

    [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = @($output)
        Text     = ($output -join [Environment]::NewLine)
    }
}

function Confirm-GitRepository {
    $result = Invoke-Git -Arguments @("rev-parse", "--is-inside-work-tree") -AllowFailure
    if ($result.ExitCode -ne 0 -or $result.Text.Trim() -ne "true") {
        throw "Run this script from inside a Git repository."
    }
}

function Resolve-Branch {
    param([Parameter(Mandatory)][string]$Branch)

    $remoteRef = "$Remote/$Branch"
    $remoteResult = Invoke-Git -Arguments @("rev-parse", "--verify", $remoteRef) -AllowFailure
    if ($remoteResult.ExitCode -eq 0) { return $remoteRef }

    $localResult = Invoke-Git -Arguments @("rev-parse", "--verify", $Branch) -AllowFailure
    if ($localResult.ExitCode -eq 0) { return $Branch }

    throw "Branch '$Branch' could not be found locally or as '$remoteRef'."
}

function Get-CommitHash {
    param([string]$Ref)
    (Invoke-Git -Arguments @("rev-parse", $Ref)).Text.Trim()
}

function Get-CommitCount {
    param([string]$RevisionRange)
    [int](Invoke-Git -Arguments @("rev-list", "--count", $RevisionRange)).Text.Trim()
}

function Get-ProjectPath {
    param([string]$Path, [int]$Depth)

    $normalized = $Path.Replace('\','/')
    $parts = $normalized.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)

    if ($parts.Count -eq 0) { return "." }

    $take = [Math]::Min($Depth, $parts.Count)
    ($parts[0..($take - 1)] -join "/")
}

function Get-FileCategory {
    param([string]$Path)

    switch -Regex ($Path) {
        '(^|/)(test|tests|spec|specs)(/|$)|Tests?\.(cs|js|ts)$' { "Tests"; break }
        '\.(sql)$|migration|migrations|database|schema' { "Database"; break }
        '(packages\.config|\.csproj$|\.sln$|package\.json$|package-lock\.json$|NuGet\.config$|Directory\.Build\.)' { "Dependencies/Build"; break }
        '(^|/)(web|app)\.config$|\.config$|\.json$|\.ya?ml$|\.env' { "Configuration"; break }
        'Dockerfile|docker-compose|kubernetes|k8s|helm|teamcity|pipeline|deploy' { "Deployment"; break }
        '\.(md|txt|rst)$' { "Documentation"; break }
        default { "Application Code" }
    }
}

function Get-ChangedFileData {
    param([string]$TargetRef, [string]$SourceRef)

    $numStat = Invoke-Git -Arguments @(
        "diff", "--numstat", "--find-renames", "$TargetRef...$SourceRef"
    )

    $nameStatus = Invoke-Git -Arguments @(
        "diff", "--name-status", "--find-renames", "$TargetRef...$SourceRef"
    )

    $statusByPath = @{}
    foreach ($line in $nameStatus.Output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t"
        if ($parts.Count -ge 2) {
            $status = $parts[0]
            $path = if ($status -match '^R' -and $parts.Count -ge 3) { $parts[2] } else { $parts[1] }
            $statusByPath[$path] = $status
        }
    }

    $files = foreach ($line in $numStat.Output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        $parts = $line -split "`t", 3
        if ($parts.Count -lt 3) { continue }

        $insertions = if ($parts[0] -eq "-") { $null } else { [int]$parts[0] }
        $deletions  = if ($parts[1] -eq "-") { $null } else { [int]$parts[1] }
        $path = $parts[2]

        [PSCustomObject]@{
            Path       = $path
            Project    = Get-ProjectPath -Path $path -Depth $FolderDepth
            Status     = if ($statusByPath.ContainsKey($path)) { $statusByPath[$path] } else { "M" }
            Insertions = $insertions
            Deletions  = $deletions
            Category   = Get-FileCategory -Path $path
            IsBinary   = ($null -eq $insertions -or $null -eq $deletions)
        }
    }

    @($files)
}

function Get-UniqueCommitData {
    param([string]$TargetRef, [string]$SourceRef)

    $result = Invoke-Git -Arguments @(
        "log",
        "--date=iso-strict",
        "--pretty=format:%H`t%ad`t%an`t%ae`t%s",
        "$TargetRef..$SourceRef"
    )

    $commits = foreach ($line in $result.Output) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 5
        if ($parts.Count -lt 5) { continue }

        $date = [datetimeoffset]::Parse($parts[1])
        $age = [int][Math]::Floor(((Get-Date) - $date.LocalDateTime).TotalDays)
        $message = $parts[4]
        $wip = $message -match '(?i)\b(WIP|temporary|prototype|spike|experiment|do not merge|disabled|cleanup later|TODO|revert|partial|draft)\b'

        [PSCustomObject]@{
            Hash       = $parts[0]
            ShortHash  = $parts[0].Substring(0, [Math]::Min(10, $parts[0].Length))
            Date       = $date.ToString("o")
            Author     = $parts[2]
            Email      = $parts[3]
            Subject    = $message
            AgeDays    = $age
            WipSignal  = $wip
        }
    }

    @($commits)
}

function Get-CommitFiles {
    param([string]$CommitHash)

    $result = Invoke-Git -Arguments @("show", "--pretty=format:", "--name-only", $CommitHash)
    @($result.Output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ProjectActivity {
    param(
        [string]$Project,
        [string]$SourceRef,
        [object[]]$UniqueCommits
    )

    $pathArg = if ($Project -eq ".") { "." } else { $Project }

    $allActivityResult = Invoke-Git -Arguments @(
        "log", "-1", "--date=iso-strict", "--pretty=format:%H`t%ad`t%an`t%s", $SourceRef, "--", $pathArg
    ) -AllowFailure

    $lastAnyCommit = $null
    if ($allActivityResult.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($allActivityResult.Text)) {
        $parts = $allActivityResult.Text -split "`t", 4
        if ($parts.Count -ge 4) {
            $dt = [datetimeoffset]::Parse($parts[1])
            $lastAnyCommit = [PSCustomObject]@{
                Hash    = $parts[0]
                Date    = $dt.ToString("o")
                Author  = $parts[2]
                Subject = $parts[3]
                AgeDays = [int][Math]::Floor(((Get-Date) - $dt.LocalDateTime).TotalDays)
            }
        }
    }

    $recentCounts = @{}
    foreach ($days in @(30,90,180,365)) {
        $since = (Get-Date).AddDays(-$days).ToString("yyyy-MM-dd")
        $countResult = Invoke-Git -Arguments @(
            "rev-list", "--count", "--since=$since", $SourceRef, "--", $pathArg
        ) -AllowFailure
        $recentCounts["Days$days"] = if ($countResult.ExitCode -eq 0 -and $countResult.Text.Trim()) { [int]$countResult.Text.Trim() } else { 0 }
    }

    $contributorsResult = Invoke-Git -Arguments @(
        "log", "--since=$((Get-Date).AddDays(-180).ToString('yyyy-MM-dd'))",
        "--format=%ae", $SourceRef, "--", $pathArg
    ) -AllowFailure

    $contributors180 = @(
        $contributorsResult.Output |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    ).Count

    [PSCustomObject]@{
        LastAnyCommit       = $lastAnyCommit
        CommitsLast30Days   = $recentCounts["Days30"]
        CommitsLast90Days   = $recentCounts["Days90"]
        CommitsLast180Days  = $recentCounts["Days180"]
        CommitsLast365Days  = $recentCounts["Days365"]
        Contributors180Days = $contributors180
    }
}

function Get-ProjectSummaries {
    param(
        [object[]]$Files,
        [object[]]$UniqueCommits,
        [string]$SourceRef
    )

    $commitProjects = @{}
    foreach ($commit in $UniqueCommits) {
        $projects = @(
            Get-CommitFiles -CommitHash $commit.Hash |
            ForEach-Object { Get-ProjectPath -Path $_ -Depth $FolderDepth } |
            Sort-Object -Unique
        )
        foreach ($project in $projects) {
            if (-not $commitProjects.ContainsKey($project)) {
                $commitProjects[$project] = New-Object System.Collections.Generic.List[object]
            }
            $commitProjects[$project].Add($commit)
        }
    }

    $summaries = foreach ($group in ($Files | Group-Object Project | Sort-Object Name)) {
        $project = $group.Name
        $projectCommits = if ($commitProjects.ContainsKey($project)) { @($commitProjects[$project]) } else { @() }
        $activity = Get-ProjectActivity -Project $project -SourceRef $SourceRef -UniqueCommits $projectCommits

        $sortedDates = @($projectCommits | Sort-Object AgeDays)
        $newest = $sortedDates | Select-Object -First 1
        $oldest = $sortedDates | Select-Object -Last 1

        $wipCount = @($projectCommits | Where-Object WipSignal).Count
        $testFiles = @($group.Group | Where-Object Category -eq "Tests").Count
        $appFiles = @($group.Group | Where-Object Category -eq "Application Code").Count
        $contributors = @($projectCommits | Select-Object -ExpandProperty Email -Unique).Count

        $classification = "Historical branch drift"
        $reasons = New-Object System.Collections.Generic.List[string]

        if ($newest) {
            if ($newest.AgeDays -le $ActiveDays) {
                $classification = "Active development"
                $reasons.Add("Newest unique change is $($newest.AgeDays) day(s) old.")
            }
            elseif ($newest.AgeDays -le $IntermittentDays) {
                $classification = "Intermittent development"
                $reasons.Add("Newest unique change is $($newest.AgeDays) day(s) old.")
            }
            elseif ($newest.AgeDays -le $AgingDays) {
                $classification = "Aging unpromoted work"
                $reasons.Add("Newest unique change is $($newest.AgeDays) day(s) old.")
            }
            else {
                $classification = "Possibly abandoned"
                $reasons.Add("No unique change in the last $AgingDays days.")
            }
        }

        if ($activity.CommitsLast180Days -gt 0 -and $classification -eq "Possibly abandoned") {
            $classification = "Historical branch drift"
            $reasons.Add("The project still has source-branch activity, so the old difference may be intentional or superseded.")
        }

        if ($wipCount -gt 0) {
            $reasons.Add("$wipCount WIP-style commit message(s) detected.")
        }

        if ($appFiles -gt 0 -and $testFiles -eq 0) {
            $reasons.Add("Application code changed without detected test-file changes.")
        }

        if ($contributors -le 1 -and $projectCommits.Count -gt 0) {
            $reasons.Add("Unique work is associated with one contributor.")
        }

        [PSCustomObject]@{
            Project                  = $project
            ChangedFiles             = $group.Count
            UniqueCommits            = $projectCommits.Count
            Contributors             = $contributors
            NewestUniqueCommitDate   = if ($newest) { $newest.Date } else { $null }
            OldestUniqueCommitDate   = if ($oldest) { $oldest.Date } else { $null }
            DaysSinceNewestUnique    = if ($newest) { $newest.AgeDays } else { $null }
            DaysSinceOldestUnique    = if ($oldest) { $oldest.AgeDays } else { $null }
            CommitsLast30Days        = $activity.CommitsLast30Days
            CommitsLast90Days        = $activity.CommitsLast90Days
            CommitsLast180Days       = $activity.CommitsLast180Days
            CommitsLast365Days       = $activity.CommitsLast365Days
            ContributorsLast180Days  = $activity.Contributors180Days
            LastAnyCommitDate        = if ($activity.LastAnyCommit) { $activity.LastAnyCommit.Date } else { $null }
            DaysSinceLastAnyCommit   = if ($activity.LastAnyCommit) { $activity.LastAnyCommit.AgeDays } else { $null }
            TestFilesChanged         = $testFiles
            ApplicationFilesChanged  = $appFiles
            WipCommitCount           = $wipCount
            Classification           = $classification
            ClassificationReasons    = @($reasons)
        }
    }

    @($summaries)
}

function Get-AgeDistribution {
    param([object[]]$Commits)

    [PSCustomObject]@{
        Total          = $Commits.Count
        NewestAgeDays  = if ($Commits.Count) { ($Commits | Measure-Object AgeDays -Minimum).Minimum } else { $null }
        OldestAgeDays  = if ($Commits.Count) { ($Commits | Measure-Object AgeDays -Maximum).Maximum } else { $null }
        MedianAgeDays  = if ($Commits.Count) {
            $ages = @($Commits.AgeDays | Sort-Object)
            if ($ages.Count % 2 -eq 1) { $ages[[int][Math]::Floor($ages.Count / 2)] }
            else { [int][Math]::Round(($ages[$ages.Count/2 - 1] + $ages[$ages.Count/2]) / 2) }
        } else { $null }
        OlderThan30    = @($Commits | Where-Object AgeDays -gt 30).Count
        OlderThan90    = @($Commits | Where-Object AgeDays -gt 90).Count
        OlderThan180   = @($Commits | Where-Object AgeDays -gt 180).Count
        OlderThan365   = @($Commits | Where-Object AgeDays -gt 365).Count
        WipSignals     = @($Commits | Where-Object WipSignal).Count
    }
}

function Get-RiskSignals {
    param([object[]]$Files, [object[]]$Projects)

    $signals = New-Object System.Collections.Generic.List[object]

    foreach ($group in ($Files | Group-Object Category | Sort-Object Count -Descending)) {
        $severity = switch ($group.Name) {
            "Database"           { "High" }
            "Configuration"      { "Medium" }
            "Deployment"         { "Medium" }
            "Dependencies/Build" { "Medium" }
            default              { "Informational" }
        }
        $signals.Add([PSCustomObject]@{
            Severity = $severity
            Signal   = "$($group.Count) changed file(s) in $($group.Name)"
        })
    }

    $stale = @($Projects | Where-Object Classification -in @("Aging unpromoted work","Possibly abandoned"))
    if ($stale.Count -gt 0) {
        $signals.Add([PSCustomObject]@{
            Severity = "Medium"
            Signal   = "$($stale.Count) project/folder area(s) contain aging or possibly abandoned work"
        })
    }

    $codeFiles = @($Files | Where-Object Category -eq "Application Code")
    $testFiles = @($Files | Where-Object Category -eq "Tests")
    if ($codeFiles.Count -gt 0 -and $testFiles.Count -eq 0) {
        $signals.Add([PSCustomObject]@{
            Severity = "Medium"
            Signal   = "Application code changed without detected test-file changes"
        })
    }

    $largeFiles = @(
        $Files | Where-Object {
            -not $_.IsBinary -and (($_.Insertions + $_.Deletions) -ge 500)
        }
    )
    if ($largeFiles.Count -gt 0) {
        $signals.Add([PSCustomObject]@{
            Severity = "Medium"
            Signal   = "$($largeFiles.Count) file(s) contain at least 500 changed lines"
        })
    }

    @($signals)
}

function ConvertTo-MarkdownTable {
    param([object[]]$Rows, [string[]]$Columns)

    if (-not $Rows -or $Rows.Count -eq 0) { return "_None_" }

    $lines = @()
    $lines += "| " + ($Columns -join " | ") + " |"
    $lines += "| " + (($Columns | ForEach-Object { "---" }) -join " | ") + " |"

    foreach ($row in $Rows) {
        $values = foreach ($column in $Columns) {
            $value = $row.$column
            if ($null -eq $value) { "" }
            elseif ($value -is [System.Array]) { (($value -join "; ").Replace("|", "\|")) }
            else { ([string]$value).Replace("|", "\|").Replace("`r","").Replace("`n"," ") }
        }
        $lines += "| " + ($values -join " | ") + " |"
    }

    $lines -join [Environment]::NewLine
}

function New-PairReport {
    param([string]$SourceBranch, [string]$TargetBranch)

    $sourceRef = Resolve-Branch $SourceBranch
    $targetRef = Resolve-Branch $TargetBranch

    $sourceHash = Get-CommitHash $sourceRef
    $targetHash = Get-CommitHash $targetRef
    $mergeBase  = (Invoke-Git -Arguments @("merge-base", $targetRef, $sourceRef)).Text.Trim()

    $sourceAhead = Get-CommitCount "$targetRef..$sourceRef"
    $targetAhead = Get-CommitCount "$sourceRef..$targetRef"

    $pairName = "$SourceBranch-to-$TargetBranch"
    $pairDirectory = Join-Path $OutputDirectory $pairName
    New-Item -ItemType Directory -Path $pairDirectory -Force | Out-Null

    $files = Get-ChangedFileData -TargetRef $targetRef -SourceRef $sourceRef
    $commits = Get-UniqueCommitData -TargetRef $targetRef -SourceRef $sourceRef
    $projects = Get-ProjectSummaries -Files $files -UniqueCommits $commits -SourceRef $sourceRef
    $ageDistribution = Get-AgeDistribution -Commits $commits
    $riskSignals = Get-RiskSignals -Files $files -Projects $projects

    $commits | Export-Csv (Join-Path $pairDirectory "commits.csv") -NoTypeInformation -Encoding UTF8
    $files   | Export-Csv (Join-Path $pairDirectory "changed-files.csv") -NoTypeInformation -Encoding UTF8
    $projects | Export-Csv (Join-Path $pairDirectory "project-activity.csv") -NoTypeInformation -Encoding UTF8

    Invoke-Git -Arguments @("diff","--stat","--find-renames","$targetRef...$sourceRef") |
        Select-Object -ExpandProperty Text |
        Set-Content (Join-Path $pairDirectory "diff-stat.txt") -Encoding UTF8

    Invoke-Git -Arguments @("diff","--binary","--find-renames","$targetRef...$sourceRef") |
        Select-Object -ExpandProperty Text |
        Set-Content (Join-Path $pairDirectory "changes.patch") -Encoding UTF8

    Invoke-Git -Arguments @("log","--left-right","--cherry-pick","--oneline","$targetRef...$sourceRef") |
        Select-Object -ExpandProperty Text |
        Set-Content (Join-Path $pairDirectory "divergence.txt") -Encoding UTF8

    $totalInsertions = ($files | Where-Object { $null -ne $_.Insertions } | Measure-Object Insertions -Sum).Sum
    $totalDeletions  = ($files | Where-Object { $null -ne $_.Deletions } | Measure-Object Deletions -Sum).Sum
    if ($null -eq $totalInsertions) { $totalInsertions = 0 }
    if ($null -eq $totalDeletions)  { $totalDeletions = 0 }

    $categorySummary = $files | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
        [PSCustomObject]@{ Category = $_.Name; Files = $_.Count }
    }

    $largestChanges = $files |
        Where-Object { -not $_.IsBinary } |
        ForEach-Object {
            [PSCustomObject]@{
                Path = $_.Path
                ChangedLines = $_.Insertions + $_.Deletions
                Category = $_.Category
            }
        } |
        Sort-Object ChangedLines -Descending |
        Select-Object -First 15

    $agingProjects = $projects |
        Where-Object Classification -in @("Aging unpromoted work","Possibly abandoned","Historical branch drift") |
        Sort-Object DaysSinceNewestUnique -Descending |
        Select-Object Project,ChangedFiles,UniqueCommits,DaysSinceNewestUnique,DaysSinceLastAnyCommit,Contributors,Classification

    $ownershipQuestions = $projects |
        Where-Object Classification -in @("Aging unpromoted work","Possibly abandoned") |
        Sort-Object DaysSinceNewestUnique -Descending |
        ForEach-Object {
            "- **$($_.Project)**: $($_.Classification). Newest unique change is $($_.DaysSinceNewestUnique) day(s) old; $($_.ChangedFiles) changed file(s); $($_.Contributors) contributor(s). Confirm whether to promote, revive, document, or remove."
        }

    if (-not $ownershipQuestions) { $ownershipQuestions = @("_None detected by the configured thresholds._") }

    $reportData = [PSCustomObject]@{
        SourceBranch = $SourceBranch
        TargetBranch = $TargetBranch
        SourceRef = $sourceRef
        TargetRef = $targetRef
        SourceCommit = $sourceHash
        TargetCommit = $targetHash
        MergeBase = $mergeBase
        SourceAhead = $sourceAhead
        TargetAhead = $targetAhead
        ChangedFiles = $files.Count
        Insertions = $totalInsertions
        Deletions = $totalDeletions
        AgeDistribution = $ageDistribution
        RiskSignals = $riskSignals
        Projects = $projects
    }

    $reportData | ConvertTo-Json -Depth 10 |
        Set-Content (Join-Path $pairDirectory "report-data.json") -Encoding UTF8

    $reviewMarkdown = @"
# Branch Review: $SourceBranch → $TargetBranch

Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss K")

## Promotion Summary

| Item | Value |
| --- | ---: |
| Source | ``$sourceRef`` |
| Source commit | ``$sourceHash`` |
| Target | ``$targetRef`` |
| Target commit | ``$targetHash`` |
| Merge base | ``$mergeBase`` |
| Source-only commits | $sourceAhead |
| Target-only commits | $targetAhead |
| Changed files | $($files.Count) |
| Insertions | $totalInsertions |
| Deletions | $totalDeletions |

## Unique Commit Age

| Metric | Value |
| --- | ---: |
| Unique commits | $($ageDistribution.Total) |
| Newest unique commit age | $($ageDistribution.NewestAgeDays) days |
| Oldest unique commit age | $($ageDistribution.OldestAgeDays) days |
| Median unique commit age | $($ageDistribution.MedianAgeDays) days |
| Older than 90 days | $($ageDistribution.OlderThan90) |
| Older than 180 days | $($ageDistribution.OlderThan180) |
| Older than 365 days | $($ageDistribution.OlderThan365) |
| WIP-style commit messages | $($ageDistribution.WipSignals) |

## Initial Interpretation

This report describes changes introduced on **$SourceBranch** relative to the common ancestor of **$SourceBranch** and **$TargetBranch**.

It does not prove that the branches merge, compile, test, or deploy successfully.

## Change Categories

$(ConvertTo-MarkdownTable -Rows $categorySummary -Columns @("Category","Files"))

## Initial Risk Signals

$(ConvertTo-MarkdownTable -Rows $riskSignals -Columns @("Severity","Signal"))

## Aging and Potentially Stagnant Work

$(ConvertTo-MarkdownTable -Rows $agingProjects -Columns @("Project","ChangedFiles","UniqueCommits","DaysSinceNewestUnique","DaysSinceLastAnyCommit","Contributors","Classification"))

## Ownership Confirmation Required

$($ownershipQuestions -join [Environment]::NewLine)

## Largest File Changes

$(ConvertTo-MarkdownTable -Rows $largestChanges -Columns @("Path","ChangedLines","Category"))

## Suggested Meeting Questions

1. Are all source-only commits intended for promotion?
2. Why does the target contain $targetAhead commit(s) not present in the source?
3. Which aging project areas still have active owners?
4. Are old differences abandoned, blocked, superseded, or intentional?
5. Are database, configuration, dependency, and deployment changes coordinated?
6. Are test changes proportional to application changes?
7. Which areas require a synthetic merge, build, test, migration, or security audit?

## AI Review Inputs

- ``report-data.json``
- ``commits.csv``
- ``changed-files.csv``
- ``project-activity.csv``
- ``diff-stat.txt``
- ``divergence.txt``
- ``changes.patch``

AI findings should distinguish confirmed evidence from inferred risk.
"@

    $reviewMarkdown | Set-Content (Join-Path $pairDirectory "review.md") -Encoding UTF8

    $reportData
}

Confirm-GitRepository

if ($Branches.Count -lt 2) { throw "Provide at least two branches." }

if (-not $SkipFetch) {
    Write-Host "Fetching $Remote and pruning obsolete references..."
    Invoke-Git -Arguments @("fetch", $Remote, "--prune") | Out-Null
}

if (Test-Path $OutputDirectory) { Remove-Item $OutputDirectory -Recurse -Force }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$pairReports = New-Object System.Collections.Generic.List[object]

for ($i = 0; $i -lt ($Branches.Count - 1); $i++) {
    Write-Host "Reviewing $($Branches[$i]) -> $($Branches[$i + 1])..."
    $pairReports.Add((New-PairReport -SourceBranch $Branches[$i] -TargetBranch $Branches[$i + 1]))
}

if ($Branches.Count -gt 2) {
    Write-Host "Reviewing end-to-end drift: $($Branches[0]) -> $($Branches[-1])..."
    $pairReports.Add((New-PairReport -SourceBranch $Branches[0] -TargetBranch $Branches[-1]))
}

$summaryRows = $pairReports | ForEach-Object {
    $possiblyAbandoned = @($_.Projects | Where-Object Classification -eq "Possibly abandoned").Count
    $aging = @($_.Projects | Where-Object Classification -eq "Aging unpromoted work").Count

    [PSCustomObject]@{
        Promotion = "$($_.SourceBranch) → $($_.TargetBranch)"
        SourceOnlyCommits = $_.SourceAhead
        TargetOnlyCommits = $_.TargetAhead
        ChangedFiles = $_.ChangedFiles
        MedianCommitAgeDays = $_.AgeDistribution.MedianAgeDays
        AgingAreas = $aging
        PossiblyAbandonedAreas = $possiblyAbandoned
    }
}

$executiveSummary = @"
# Branch Promotion Review

Generated: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss K")

Branches reviewed:

```
$($Branches -join " → ")
```

## Promotion Overview

$(ConvertTo-MarkdownTable -Rows $summaryRows -Columns @(
    "Promotion",
    "SourceOnlyCommits",
    "TargetOnlyCommits",
    "ChangedFiles",
    "MedianCommitAgeDays",
    "AgingAreas",
    "PossiblyAbandonedAreas"
))

## Scope

This first-pass packet covers:

- Commit divergence
- Changed-file inventory
- Change volume
- Unique commit age
- Project/folder activity
- Conservative stagnation classifications
- WIP-style commit-message clues
- AI-reviewable patches and structured data

It does not yet cover:

- Actual merge conflicts
- Compilation
- Automated tests
- Dependency restore
- Database migration execution
- Security scanning
- Deployment validation
- Runtime compatibility

## Recommended Meeting Sequence

1. Review target-only commits and branch drift.
2. Review aging and possibly abandoned project areas.
3. Confirm ownership and intent.
4. Review database, configuration, dependency, and deployment changes.
5. Select the scope of the larger synthetic-merge and build audit.
"@

$executiveSummary | Set-Content (Join-Path $OutputDirectory "executive-summary.md") -Encoding UTF8
$pairReports | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutputDirectory "branch-data.json") -Encoding UTF8

Write-Host ""
Write-Host "Branch review generated successfully:"
Write-Host (Resolve-Path $OutputDirectory)
Write-Host ""
Write-Host "Start with:"
Write-Host "  $(Join-Path $OutputDirectory 'executive-summary.md')"
