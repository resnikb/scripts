####################################################################################################################
# This is a small utility script that implements basic workflow with git-tfs.
#
# Syntax: tfs_git.ps1 [push | pull | mergetrunk]
#
# The implement workflow is the following:
#   1. git-tfs is used to clone TFS repository and to maintain the bridge between git and TFS
#   2. master branch is *always* the same as TFS = NO GIT COMMITS IN THE MASTER BRANCH
#   3. All work is done in feature branches
#   4. Pulling changes from TFS:
#         - Switch to master
#         - git tfs pull
#         - Switch to feature branch
#         - git rebase master
#   5. Pushing changes to TFS:
#         - On a feature branch
#         - git tfs checkintool
#
# For convenient usage, you can add both push and pull to VisualStudio as external commands.
####################################################################################################################
Param
(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('push', 'pull', 'mergetrunk')]
    $Action
)

function Get-GitBranch {
    return (git branch | Select-String "\*").ToString().Substring(1).Trim()
}

function Test-GitRebaseInProgress {
    $rootDir = git 'rev-parse' '--show-toplevel'
    return (Test-Path -PathType Container (Join-Path $rootDir 'rebase-apply')) -or (Test-Path -PathType Container (Join-Path $rootDir 'rebase-merge'))
}

function Test-GitUncommittedChanges {
    $output = git status -z
    return ( ($output -ne $null) -and ($output.Trim() -ne "") )
}

function Run-GitExtensions {
    Param
    (
        [Parameter(Mandatory=$false, Position=0)]
        [String[]]
        $ArgumentList,

        [Parameter(Mandatory=$false)]
        [Switch]
        $NoWait = $false
    )

    $gitex = Get-Command gitex -TotalCount 1

    # In case this is an alias, resolve it into actual path
    if ((Test-Path $gitex) -eq $false) {
        $gitex = $gitex.Definition
    }

    if ([System.IO.Path]::GetExtension($gitex) -ne '.exe') {
        $gitex = [System.IO.Path]::Combine([System.IO.Path]::GetDirectoryName($gitex), 'GitExtensions.exe')
        if ((Test-Path $gitex) -eq $false) {
            Write-Host "** Cannot find $gitex"
            Exit 1
        }
    }

    $process = Start-Process $gitex -ArgumentList $ArgumentList -PassThru
    if ($NoWait -eq $false) {
        $process.WaitForExit()
    }
}

function Resolve-MergeConflicts {
    while ( (Test-GitUncommittedChanges) -and (Test-GitRebaseInProgress) ) {
        Write-Host -Foreground Red '* Conflicts detected, please resolve to continue'
        Run-GitExtensions mergeconflicts
        if ($LastExitCode -ne 0) {
            Write-Host -Foreground Red '* Failed to rebase -- please fix manually'
            Exit 1
        }

        git rebase '--continue'
    }

    if (Test-GitUncommittedChanges) {
        Write-Host -Foreground Red '* Unexpected changes in working tree, please fix manually'
        Exit 1
    }
}

function New-BranchMapping {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $Definitions
    )

    $result = @()
    [regex]$reDefinition = '(?imn)^\s*(?<source>.+?)\s*:\s*(?<target>.+?)\s*(#.*)?$'
    foreach ($match in $reDefinition.Matches($Definitions)) {
        $result += New-Object 'Tuple[string, string]'("^$($match.Groups['source'].Value)$", $match.Groups['target'])
    }

    return $result
}

function Get-FeatureBranch {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $Branch
    )

    # Branch mapping is
    if (!$script:branchMapping) {
        $script:branchMapping = New-BranchMapping '
            Develop: master
            Dev: master
            Refactor_.+: master     # Refactoring branches map to master
            Dev_(.+): $1            # Convention: main development for feature branches is done on a Dev_ branch
        '
    }

    $result = $script:branchMapping | ?{ $Branch -match $_.Item1 } | %{ $Branch -replace $_.Item1, $_.Item2 } | Select-Object -First 1
    if ($result) {
        return $result
    }
    return $Branch
}

function Get-TfsRemote {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $Branch
    )

    $featureBranch = Get-FeatureBranch $Branch
    if ($featureBranch -eq 'master') {
        return 'default'
    }

    $branches = @(git branch -r | %{ $_.Trim() })
    $candidates = ($Branch, $featureBranch)
    return $candidates | ?{ "tfs/$_" -in $branches } | Select-Object -First 1
}

function Test-NewCommits {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $Branch,

        [Parameter(Mandatory=$true, Position=1)]
        [String]
        $ParentBranch
    )

    # Get the number of commits on $Branch that are not in $ParentBranch
    $changes = (git rev-list --left-only --count "$Branch...$ParentBranch").Trim()
    if ($changes -eq '0') {
        return $false
    }

    Write-Host -Foreground Yellow "* Found $changes new commits in $Branch"
    return $true
}

function Rebase-IfNeeded {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $Branch,

        [Parameter(Mandatory=$true, Position=1)]
        [String]
        $ParentBranch
    )

    if (Test-NewCommits $ParentBranch $Branch) {
        Write-Host -Foreground Green "* Rebasing '$Branch' on '$ParentBranch'"
        git rebase -q --preserve-merges $ParentBranch
        Resolve-MergeConflicts
    }
}

function Pull-FromTfs {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $currentBranch,

        [Parameter(Mandatory=$true, Position=1)]
        [String]
        $featureBranch,

        [Parameter(Mandatory=$true, Position=2)]
        [String]
        $tfsRemote
    )

    Write-Host -Foreground Green "* Getting latest changes from branch '$featureBranch'"
    if ($featureBranch -ne (Get-GitBranch)) {
        git checkout $featureBranch --force
    }

    git tfs fetch --parents -i $tfsRemote
    Rebase-IfNeeded $featureBranch "tfs/$tfsRemote"

    if ($currentBranch -ne (Get-GitBranch)) {
        git checkout $currentBranch
        Rebase-IfNeeded $currentBranch $featureBranch
    }
}

function Push-ToTfs {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $currentBranch,

        [Parameter(Mandatory=$true, Position=1)]
        [String]
        $featureBranch,

        [Parameter(Mandatory=$true, Position=2)]
        [String]
        $tfsRemote
    )

    Pull-FromTfs $currentBranch $featureBranch $tfsRemote
    git tfs rcheckin -i $tfsRemote

    if ($LastExitCode -eq 254) {
        Write-Host -Foreground Yellow "* Regular checkin failed, trying to push without rebasing (less safe)"

        git checkout $currentBranch --force
        git tfs rcheckin -q -i $tfsRemote
    }

    if ($LastExitCode -ne 0) {
        Write-Host -Foreground Red "* Failed to push to TFS"
    }
}

function Merge-TrunkIntoFeatureBranch {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $currentBranch,

        [Parameter(Mandatory=$true, Position=1)]
        [String]
        $featureBranch,

        [Parameter(Mandatory=$true, Position=2)]
        [String]
        $tfsRemote
    )

    Pull-FromTfs master master default

    if ($featureBranch -ne 'master') {
        Pull-FromTfs $featureBranch $featureBranch $tfsRemote

        # Then merge trunk into the feature branch (note that we are merging tfs/default to avoid any local changes on master branch)
        Write-Host -Foreground Green "* Merging trunk into branch $featureBranch"
        $commitMessage = "Merged trunk into branch $featureBranch"
        git merge --commit --no-ff --no-edit -q -m "$commitMessage" tfs/default

        # ... and resolve any merge conflicts along the way
        if (Test-GitUncommittedChanges) {
            Write-Host -Foreground Red '* Conflicts detected, please resolve to continue'
            Run-GitExtensions mergeconflicts
            if ($LastExitCode -ne 0) {
                Write-Host -Foreground Red "* Failed to merge -- please fix manually"
                Exit 1
            }

            git commit -a --no-edit -q -m "$commitMessage"
        }

        # Push the merge to TFS
        if ((Test-NewCommits $featureBranch "tfs/$tfsRemote")) {
            Write-Host -Foreground Green "* Pushing feature branch '$featureBranch' to TFS branch 'tfs/$tfsRemote'"
            git tfs rcheckin -i $tfsRemote
        } else {
            Write-Host -Foreground Yellow '* No new commits created, nothing will be pushed to TFS'
        }
    }

    if ($currentBranch -ne (Get-GitBranch)) {
        git checkout $currentBranch
        Rebase-IfNeeded $currentBranch $featureBranch
    }
}

$currentBranch = Get-GitBranch
$featureBranch = Get-FeatureBranch $currentBranch
$tfsRemote = Get-TfsRemote $currentBranch

if (!$tfsRemote) {
    Write-Host -Foreground Red "* Cannot find TFS remote for branch $currentBranch"
    Exit 1
}

Write-Host -Foreground Green "*     Git Branch: $currentBranch"
if ($featureBranch -ne $currentBranch) {
    Write-Host -Foreground Green "* Feature Branch: $featureBranch"
}
Write-Host -Foreground Green "*     TFS Branch: tfs/$tfsRemote"
Write-Host

$hasStash = Test-GitUncommittedChanges
if (Test-GitUncommittedChanges) {
    Write-Host -Foreground Yellow "* There are uncommitted changes in branch $currentBranch. Creating a stash"
    git stash save -u
}

if ($Action -eq 'push') {
    Push-ToTfs $currentBranch $featureBranch $tfsRemote
} elseif ($Action -eq 'pull') {
    Pull-FromTfs $currentBranch $featureBranch $tfsRemote
} elseif ($Action -eq 'mergetrunk') {
    Merge-TrunkIntoFeatureBranch $currentBranch $featureBranch $tfsRemote
}

if ($hasStash) {
    Write-Host -Foreground Green '* Restoring stashed changes'
    git stash pop
}
Write-Host -Foreground Green '** Completed **'
