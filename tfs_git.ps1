####################################################################################################################
# This is a small utility script that implements basic workflow with git-tfs.
#
# Syntax: tfs_git.ps1 [push | pull]
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
    [ValidateSet("push", "pull")]
    $Action
)

function Get-GitBranch {
    return (git branch | Select-String "\*").ToString().Substring(1).Trim()
}

function Test-GitUncommittedChanges {
    $output = git status -z
    return ( ($output -ne $null) -and ($output.Trim() -ne "") )
}

function Get-TfsRemoteSpec {
    $branch = Get-GitBranch
    if ( (& git branch '-r' | Select-String "/$branch") -eq $null ) {
        return $null
    }

    return $branch
}

function Run-GitTfsCommand {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String]
        $Command
    )

    $remote = Get-TfsRemoteSpec
    if ($remote) {
        & git tfs $Command -i "`"$remote`""
    } else {
        & git tfs $Command
    }
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

    $process = Start-Process $gitex -ArgumentList $ArgumentList -PassThru
    if ($NoWait -eq $false) {
        $process.WaitForExit()
    }
}

function Push-ToTfs {
    $branch = Get-GitBranch

    # Pull before pushing
    Pull-FromTfs
    
    #git tfs checkintool
    Run-GitTfsCommand rcheckin
    if ($LastExitCode -ne 0) {
        Write-Host "* Failed to push to TFS"
        if ($branch -ne "master") {
            git checkout $branch --force
        }
    }
}

function Pull-FromTfs {
    $branch = Get-GitBranch
    if (Test-GitUncommittedChanges) {
        Write-Host "* There are uncommitted changes in branch $branch. Please commit or reset to continue"
        Run-GitExtensions commit
        
        if (Test-GitUncommittedChanges) {
            Write-Host "* Cannot continue due to uncommitted changes"
            Exit
        }
    }
    
    $remote = Get-TfsRemoteSpec
    $isTrunkBased = ($branch -ne "master") -and ($remote -eq $null)
    if ($isTrunkBased) {
        git checkout master --force
    }
    
    Write-Host "* Pulling changes from TFS $(if ($isTrunkBased -eq $false) {'(branch '+$remote+')'})"
    Run-GitTfsCommand pull
    if ($isTrunkBased) {
        Write-Host "* Rebasing branch '$branch' on master"
        git checkout $branch --force
        git rebase -q master
        while (Test-GitUncommittedChanges) {
            Write-Host "* Rebase conflicts detect, please resolve to continue"
            Run-GitExtensions mergeconflicts
            if ($LastExitCode -ne 0) {
                Write-Host "* Failed to rebase -- please fix manually"
                Exit
            }
            & git rebase "--continue"
        }
    }
}

# Set TFS client to use, to prevent errors with missing policy assemblies
$env:GIT_TFS_CLIENT="2010"

if ($Action -eq "push") {
    Push-ToTfs
} else {
    Pull-FromTfs
}

Write-Host "** Completed **"
