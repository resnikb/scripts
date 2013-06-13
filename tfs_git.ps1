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

function Get-TfsRemoteBranches {
    return @(
        git branch -r `
            | %{ $_.Split('/')[-1].Trim() } `
            | %{ if ($_ -eq 'default') {'master'} else {$_} }
    )
}

function Get-GitBranchParent {
    $branch = Get-GitBranch
    $allRemoteBranches = Get-TfsRemoteBranches

    if ($allRemoteBranches -contains $branch) {
        return $branch
    }

    foreach ($remoteBranch in $allRemoteBranches) {
        $candidates = @(
            & git 'merge-base' $branch $remoteBranch `
                | %{ & git branch '--contains' $_ } `
                | %{ if ($_.StartsWith('*')) { $_.Substring(1).Trim() } else { $_.Trim() } } `
                | ?{ $allRemoteBranches -contains $_ }
        )

        if ($candidates.Length -eq 1) {
            return $candidates[0]
        }

        # If the only candidates are 'master' and another branch, prefer the other branch
        # This caters for the case when a TFS branch is at the same commit as the trunk,
        # and we are working off the branch
        if ( ($candidates.Length -eq 2) -and ($candidates -contains 'master') ) {
            return $candidates | ?{ $_ -ne 'master' }
        }
    }

    throw "Cannot find unique TFS branch for '$branch'"
}

function Run-GitTfsCommand {
    Param
    (
        [Parameter(Mandatory=$true, Position=0)]
        [String[]]
        $Params
    )

    $remote = Get-TfsRemoteSpec
    if ($remote) {
        $Params += @('-i', "`"$remote`"")
        & git tfs $Params
    } else {
        & git tfs $Params
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

function Push-ToTfs {
    $branch = Get-GitBranch

    # Pull before pushing
    Pull-FromTfs
    
    #git tfs checkintool
    Run-GitTfsCommand rcheckin
    if ($LastExitCode -ne 0) {
        Write-Host "* Failed to push to TFS"
    }

    if ($branch -ne (Get-GitBranch)) {
        git checkout $branch --force
    }
}

function Pull-FromTfs {
    $branch = Get-GitBranch
    $remoteBranch = Get-GitBranchParent

    if (Test-GitUncommittedChanges) {
        Write-Host "* There are uncommitted changes in branch $branch. Please commit or reset to continue"
        Run-GitExtensions commit
        
        if (Test-GitUncommittedChanges) {
            Write-Host "* Cannot continue due to uncommitted changes"
            Exit
        }
    }
    
    # Checkout the TFS tracking branch
    if ($remoteBranch -ne $branch) {
        git checkout $remoteBranch --force
    }
    
    Write-Host "* Pulling changes from TFS $(if ($remoteBranch -ne 'master') {'(branch '+$remoteBranch+')'})"
    Run-GitTfsCommand @('pull', '--rebase')
    
    if ($remoteBranch -ne $branch) {
        Write-Host "* Rebasing branch '$branch' on $remoteBranch"
        git checkout $branch --force
        git rebase -q $remoteBranch
    }

    while (Test-GitUncommittedChanges) {
        Write-Host "* Conflicts detected, please resolve to continue"
        Run-GitExtensions mergeconflicts
        if ($LastExitCode -ne 0) {
            Write-Host "* Failed to rebase -- please fix manually"
            Exit
        }
        & git rebase "--continue"
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
