####################################################################################################################
# This is a small utility script that implements basic workflow with git-tfs.
#
# Syntax: tfs_git.ps1 [push | pull]
#
# The implement workflow is the following:
#	1. git-tfs is used to clone TFS repository and to maintain the bridge between git and TFS
#	2. master branch is *always* the same as TFS = NO GIT COMMITS IN THE MASTER BRANCH
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
	$process = Start-Process $gitex -ArgumentList $ArgumentList -PassThru
	if ($NoWait -eq $false) {
		$process.WaitForExit()
	}
}

function Push-ToTfs {
	$branch = Get-GitBranch

	# Pull before pushing
	Pull-FromTfs
	
	git tfs checkintool
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
	
	if ($branch -ne "master") {
		git checkout master --force
	}
	
	Write-Host "* Pulling changes from TFS"
	git tfs pull
	if ($branch -ne "master") {
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

if ($Action -eq "push") {
	Push-ToTfs
} else {
	Pull-FromTfs
}

Write-Host "** Completed **"
