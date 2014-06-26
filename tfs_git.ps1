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
    [ValidateSet('Push', 'Pull', 'MergeTrunk', 'MergeBranch', 'StartFeature')]
    $Action,

    [Parameter(Mandatory=$false, Position=1)]
    [String]
    $Name
)

function Get-LocalOrParentPath($path) {
    $checkIn = Get-Item -Force .
    while ($checkIn -ne $null) {
        $pathToTest = [System.IO.Path]::Combine($checkIn.fullname, $path)
        if (Test-Path -LiteralPath $pathToTest) {
            return $pathToTest
        } else {
            $checkIn = $checkIn.parent
        }
    }
    return $null
}

function Get-GitBranch {
    # On Windows (or case insensitive systems in general), git will not mark a branch with *
    # if it has been checked out using a different case (e.g. your branch is XYZ but you checked it out as xyz).
    # If that is the case, we'll try a few other approaches to get the current branch
    $branch = git branch 2>$null | Select-String '\*'
    if ($branch -ne $null) {
        return $branch.ToString().Substring(1).Trim()
    }

    $branch = git symbolic-ref HEAD 2>$null
    if ($branch -ne $null) {
        $refDir = $branch.ToString().Trim()
        $branch = Split-Path -Leaf $refDir
        $gitDir = Get-LocalOrParentPath .git
        if ($gitDir -ne $null) {
            # The magic symbol here is * which forces Get-Item to enumerate matching file system entries
            # and return them in their correct case.
            # Without it, Get-Item would return the entry exactly as it was in $refDir
            $branchDir = Get-Item -Force "$gitDir/$refDir*" | ?{ $_.Name -eq $branch } | Select-Object -First 1
            if ($branchDir -ne $null) {
                return $branchDir.Name
            }
        }

        return $branch
    }
}

function Get-GitDir {
    $rootDir = git 'rev-parse' '--show-toplevel' 2>$null
    return (Join-Path $rootDir '.git')
}

function Test-GitRebaseInProgress {
    $gitDir = Get-GitDir
    return (Test-Path -PathType Container (Join-Path $gitDir 'rebase-apply')) -or (Test-Path -PathType Container (Join-Path $gitDir 'rebase-merge'))
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

function Test-GitConflicts {
    $diff = git diff --name-only --diff-filter=U
    if ($diff -eq $null) {
        return $false
    }

    return $diff.ToString().Trim() -ne ''
}

function Git-Rcheckin {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $Remote,

        [Parameter(Mandatory=$false, Position=1)]
        [Switch]
        $Quick=$false
    )

    $qCommand = ''
    if ($Quick) {
        $qCommand = '-q'
    }

    # Use Tee-Object here to send output to both console and variable
    git tfs rcheckin -i $Remote -a --no-build-default-comment $qCommand | Tee-Object -Variable rcheckinOutput
    $script:rcheckinOutput = $rcheckinOutput
}

function Resolve-MergeConflicts {
    Param
    (
        [Parameter(Mandatory=$false, Position=0)]
        [Switch]
        $AllowUncommittedChanges=$false
    )

    while ( (Test-GitConflicts) -and (Test-GitRebaseInProgress) ) {
        Write-Host -Foreground Red '* Conflicts detected, please resolve to continue'
        $elapsedTime = Measure-Command { Run-GitExtensions mergeconflicts }

        if ($elapsedTime.TotalSeconds -le 5) {
            $LastExitCode = 0
            Write-Host -Foreground Yellow '* Waiting for you to resolve conflicts manually, press ENTER to continue'
            do
            {
                $key = $host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            }
            while ($key.VirtualKeyCode -ne 13)
        }

        if (($LastExitCode -ne 0) -or (Test-GitConflicts)) {
            Write-Host -Foreground Red '* Failed to rebase -- please fix manually'
            Exit 1
        }

        git rebase '--continue'
    }

    if (!$AllowUncommittedChanges -and (Test-GitUncommittedChanges)) {
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

            # Git-flow compatible naming
            # feature/.+: $0        # No rule needed for feature branches - they should just map to themselves
            hotfix/.+: master       # Hotfix branches are done off trunk and usually do not have a matching TFS branch
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
        git rebase -q --preserve-merges --autosquash $ParentBranch  # Note the use of autosquash to process any in-comment commands and preserve-merges to preserve merges
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

    # Use a script-level array to store the branches we have already pulled from.
    # This will prevent multiple pulls of the same branch
    if (!$script:BranchesPulledFrom) {
        $script:BranchesPulledFrom = @()
    }
    $alreadyPulled = $false
    if ($featureBranch -in $script:BranchesPulledFrom) {
        $alreadyPulled = $true
    } else {
        $script:BranchesPulledFrom += @($featureBranch)
    }

    if (!$alreadyPulled) {
        if ($featureBranch -ne 'master') {
            Pull-FromTfs master master default
        }

        Write-Host -Foreground Green "* Getting latest changes from branch '$featureBranch'"

        if ($featureBranch -ne (Get-GitBranch)) {
            git checkout $featureBranch --force
        }

        git tfs fetch -i $tfsRemote
        Rebase-IfNeeded $featureBranch "tfs/$tfsRemote"
    }

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

    Git-Rcheckin $tfsRemote

    if ($LastExitCode -eq 254) {
        Write-Host -Foreground Yellow "* Regular checkin failed, trying to push without rebasing (less safe)"

        git checkout $currentBranch --force
        Git-Rcheckin $tfsRemote -Quick
    }

    if ($LastExitCode -ne 0) {
        Write-Host -Foreground Red "* Failed to push to TFS"
    }
}

function Merge-Branch {
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
        $tfsRemote,

        [Parameter(Mandatory=$true, Position=3)]
        [String]
        $branchToMerge
    )

    $canUseCheckinTool = $true
    if (($branchToMerge -eq 'master') -or ($featureBranch -eq 'master') -or ($currentBranch -eq 'master')) {
        $canUseCheckinTool = $false
    }

    $tfsRemoteToMerge = Get-TfsRemote $branchToMerge
    Pull-FromTfs $branchToMerge $branchToMerge $tfsRemoteToMerge

    if ($featureBranch -ne $branchToMerge) {
        Pull-FromTfs $featureBranch $featureBranch $tfsRemote

        # There are new commits on this branch - we don't want to push those
        # We only want to push the merge (when it happens).
        # So, we create a temporary branch to hold current state
        if (Test-NewCommits $featureBranch "tfs/$tfsRemote") {
            $tempBranch = "$featureBranch-$([System.Guid]::NewGuid().ToString('N'))"
            Write-Host -Foreground Yellow "* Branch '$featureBranch' has local commits - creating temporary branch '$tempBranch' to hold them"
            git branch $tempBranch $featureBranch
            git reset --hard "tfs/$tfsRemote"
        }

        try {
            # Then merge into the feature branch (note that we are merging tfs remote to avoid any local changes on source branch)
            Write-Host -Foreground Green "* Merging $branchToMerge into branch $featureBranch"
            $commitMessage = "Merged $branchToMerge into branch $featureBranch"
            git merge --commit --no-ff --no-edit --no-log -q -m "$commitMessage" "tfs/$tfsRemoteToMerge"

            # ... and resolve any merge conflicts along the way
            if (Test-GitUncommittedChanges) {
                Write-Host -Foreground Red '* Conflicts detected, please resolve to continue'
                Run-GitExtensions mergeconflicts
                if (($LastExitCode -ne 0) -or (Test-GitConflicts)) {
                    Write-Host -Foreground Red "* Failed to merge -- please fix manually"
                    Exit 1
                }

                git commit -a --no-edit -q -m "$commitMessage"
            }

            # Push the merge to TFS
            if ((Test-NewCommits $featureBranch "tfs/$tfsRemote")) {
                Write-Host -Foreground Green "* Pushing feature branch '$featureBranch' to TFS branch 'tfs/$tfsRemote'"
                Git-Rcheckin $tfsRemote
                Resolve-MergeConflicts

                $failedMessage =  $script:rcheckinOutput | ?{ $_ -like '*The item*is not a branch of*' } | Select-Object -First 1
                if ($canUseCheckinTool -and ($failedMessage -ne $null)) {
                    Write-Host -Foreground Yellow "* Regular checkin failed, trying with checkintool"
                    git tfs checkintool -i $tfsRemote --no-build-default-comment -m "$commitMessage"
                }

                if ($LastExitCode -ne 0) {
                    Write-Host -Foreground Red '** Failed to push to TFS'
                    return 1
                }
            } else {
                Write-Host -Foreground Yellow '* No new commits created, nothing will be pushed to TFS'
            }
        } finally {
            if ($tempBranch) {
                Write-Host -Foreground Yellow "* Restoring local commits for '$featureBranch'"
                git checkout $tempBranch --force
                Rebase-IfNeeded $tempBranch $featureBranch
                git checkout $featureBranch --force
                git reset --hard $tempBranch
                git branch -D $tempBranch
            }
        }
    }

    if ($currentBranch -ne (Get-GitBranch)) {
        git checkout $currentBranch
        Rebase-IfNeeded $currentBranch $featureBranch
    }

    return 0
}

function New-FeatureBranch {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $Feature
    )

    if (!$Feature) {
        Write-Host -Foreground Red "Feature name not specified"
        return 1
    }

    if ((Get-GitBranch) -ne 'master') {
        git checkout master --force
    }

    if ($Feature -like '*-*') {
        $tfsFeature = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($Feature.ToLowerInvariant()).Replace('-', '')
    } else {
        $tfsFeature = $Feature
    }

    $gitBranch = $Feature
    $tfsBranchPath = @(git tfs branch -r `
                        | %{ $_.Split('$') | Select-Object -Last 1 } `
                        | ?{ $_ -ne '' -and $tfsFeature -eq (Split-Path -Leaf $_) })

    if (!$tfsBranchPath -or ($tfsBranchPath.Length -eq 0)) {
        $tfsProjectRoot = git tfs branch `
                            | ?{ $_ -like '*default ->*' } `
                            | %{ $_.Split('$') } `
                            | Select-Object -Last 1 `
                            | Split-Path -Parent `
                            | %{ $_.Replace('\', '/') }

        $tfsBranchPath = "`$$tfsProjectRoot/branches/$tfsFeature"

        Write-Host -Foreground Green "* Creating TFS branch '$tfsBranchPath' and local git branch '$gitBranch'"
        git tfs branch $tfsBranchPath $gitBranch --comment="Created branch $Feature"
    } elseif ($tfsBranchPath.Length -eq 1) {
        $tfsBranchPath = "`$$tfsBranchPath"
        Write-Host -Foreground Green "* Using existing TFS branch '$tfsBranchPath' and creating local git branch '$gitBranch'"
        git tfs branch --init $tfsBranchPath $gitBranch
    } else {
        Write-Host -Foreground Red "* Cannot initialise branch for feature '$Feature', multiple TFS branches exist: $([string]::join(', ', $tfsBranchPath)), $($tfsBranchPath.Length)"
        return 1
    }

    if ($gitBranch -ne (Get-GitBranch)) {
        # Sometimes git tfs fails to create local git branch, so we have to
        # This will checkout the branch if it exists and create it if it doesn't
        $branches = git branch | ?{ $_ -like "* $gitBranch"} | Select-Object -First 1
        if ($branches -ne $null) {
            git checkout $gitBranch
        } else {
            git checkout tfs/$tfsFeature -b $gitBranch
        }
    }

    return 0
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
    $exitCode = Merge-Branch $currentBranch $featureBranch $tfsRemote master
} elseif ($Action -eq 'StartFeature') {
    $exitCode = New-FeatureBranch $Name
} elseif ($Action -eq 'MergeBranch') {
    $exitCode = Merge-Branch $currentBranch $featureBranch $tfsRemote $Name
}

if ($hasStash -and ($currentBranch -eq (Get-GitBranch))) {
    Write-Host -Foreground Green '* Restoring stashed changes'
    git stash pop
    Resolve-MergeConflicts -AllowUncommittedChanges
}
Write-Host -Foreground Green '** Completed **'
if ($exitCode) {
    Exit $exitCode
}
