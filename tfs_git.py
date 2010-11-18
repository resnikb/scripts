import argparse
import io
import cStringIO
import os
import re
import subprocess
import sys
import Tkinter
import tkMessageBox

class ExternalCommand(object):
    def __init__(self, path = None, working_directory = None):
        super(ExternalCommand, self).__init__()
        self.__path = path
        self.__useShell = not os.path.isfile(path)
        self.working_directory = working_directory
        self.redirect = True
        
    def run_simple(self, args, redirect, startDirectory):
        do_redirect = redirect or self.redirect
        p = subprocess.Popen(
            args,
            stderr = subprocess.STDOUT,
            stdout = subprocess.PIPE if do_redirect else None,
            cwd = startDirectory,
            shell = self.__useShell
        )
        
        out = cStringIO.StringIO()
        while p.returncode is None:
            stdout, stderr = p.communicate()
            if stdout:
                out.write(stdout)
                    
        # Try to get any leftover output
        try:
            stdout, stderr = p.communicate()
            if stdout:
                out.write(stdout)
        except:
            pass
            
        code = p.returncode
        output = out.getvalue().strip()
        
        if (self.redirect and not redirect) or code:
            if code:
                sys.stdout.write("** (%d) %s\n" % (code, subprocess.list2cmdline(args)))
            
            sys.stdout.write(output)
            sys.stdout.write('\n')
            
            if code:
                sys.stdout.write("**\n\n")
                
            sys.stdout.flush()
            
        return (code, output)
    
    def run(self, *args, **kwargs):
        redirect = kwargs.get("redirect", True)
        startDirectory = kwargs.get("start_in", self.working_directory)
        variables = list(kwargs.get("variables", []))
            
        base_command = [self.__path] + list(args)
        if not variables:
            return self.run_simple(base_command, redirect, startDirectory)
            
        base_length = sum(len(x) for x in base_command)
        
        code = 0
        output = ''
        while variables:
            command = base_command[:]
            length = base_length
            while variables and length < 1500:
                x = variables.pop()
                length += len(x)
                command.append(x)
                
            result = self.run_simple(command, redirect, startDirectory)
            code += result[0]
            output += result[1]
            
        return (code, output)
        
    def run_checked(self, *args, **kwargs):
        code, output = self.run(*args, **kwargs)
        if code:
            raise Exception("Error executing command")
            
        return output

class Status(object):
    ADDED     = 'A'
    MODIFIED  = 'M'
    COPIED    = 'C'
    RENAMED   = 'R'
    DELETED   = 'D'
    UNTRACKED = '?'
    
    def __init__(self, basePath):
        super(Status, self).__init__()
        self.base_path = basePath
        self.__operations = {
            Status.ADDED     : set(), 
            Status.MODIFIED  : set(),
            Status.COPIED    : set(),
            Status.RENAMED   : set(),
            Status.DELETED   : set(),
            Status.UNTRACKED : set()
        }
        
    @property
    def added(self):
        return self.__operations[Status.ADDED]
        
    @property
    def modified(self):
        return self.__operations[Status.MODIFIED]
        
    @property
    def copied(self):
        return self.__operations[Status.COPIED]
        
    @property
    def renamed(self):
        return self.__operations[Status.RENAMED]
        
    @property
    def deleted(self):
        return self.__operations[Status.DELETED]
        
    @property
    def untracked(self):
        return self.__operations[Status.UNTRACKED]
        
    def __len__(self):
        return sum( len(x) for x in self.__operations.itervalues() )
        
    def __str__(self):
        with io.StringIO() as s:
            for status, paths in self.__operations.iteritems():
                for path in paths:
                    s.write(status + u' ' + path + u'\n')
            return s.getvalue()
        
    def add(self, status, path):
        # Renamed and copied entries have an arrow pointing from source to destination
        if status in [Status.RENAMED, Status.COPIED]:
            path = tuple(x.strip() for x in path.split('->', 1))
            
        self.__operations[status].add(path)
        
class Git(ExternalCommand):
    def __init__(self, path = None, working_directory = None):
        super(Git, self).__init__(path or "git", working_directory)
        
    def find_root(self):
        output = self.run_checked("rev-parse", "--show-toplevel")
        return os.path.normpath(output)
        
    @property
    def branch_name(self):
        return os.path.basename(self.run_checked("symbolic-ref", "HEAD"))
        
    def get_status(self):
        output = self.run_checked("status", "--porcelain")
        lines = [x.strip() for x in output.split('\n')]
            
        result = Status(self.working_directory)
        for line in lines:
            parts = line.split(' ', 1)
            if len(parts) == 2:
                file_status = parts[0].strip()
                file_name = parts[1].strip()
                result.add(file_status[0], file_name)
                
        return result
        
    def reset(self, hard=False):
        args = ["reset"]
        if hard:
            args.append("--hard")
            
        self.run_checked(*args)

    def clean(self):
        self.run_checked("clean", "-df")
    
    def checkout(self, branch, force=False):
        args = ["checkout", branch]
        if force:
            args.append("-f")
            
        self.run_checked(*args, redirect=False)
        
    def rebase(self, branch):
        self.run_checked("rebase", branch, redirect=False)
        
    def add_all(self):
        self.run_checked("add", "-A", redirect=False)
        
    def commit(self, message):
        self.run_checked("commit", "-m", message, redirect=False)
        
    def merge(self, branch, squash=False):
        args = ["merge"]
        if squash:
            args.append("--squash")
        args.append(branch)
        
        self.run_checked(*args)
        
    def reset_and_clean(self):
        self.reset(hard=True)
        self.clean()

class Tfs(ExternalCommand):
    def __init__(self, path = None, working_directory = None):
        super(Tfs, self).__init__(path or r"c:\Program Files (x86)\Microsoft Visual Studio 10.0\Common7\IDE\tf.exe", working_directory)
        
    def get_latest(self):
        code, output = self.run("get", ".", "/recursive", "/overwrite", "/noprompt", redirect=False)
        return code != 100 and "up to date" not in output.lower()
        
    def checkout(self, paths):
        self.run("checkout", variables=paths, redirect=False)
        
    def delete(self, paths):
        self.run("delete", variables=paths, redirect=False)
        
    def rename(self, tuples):
        # Checkout old files first
        self.checkout(x[0] for x in tuples)
        
        for old_name, new_name in tuples:
            self.run("rename", old_name, new_name, redirect=False)
        
    def add(self, paths):
        self.run("add", "/noprompt", variables=paths, redirect=False)
        
    def copy(self, tuples):
        self.add(x[1] for x in tuples)
        
    def undo(self, paths, recursive=False):
        args = ["undo", "/noprompt"]
        if recursive:
            args.append("/recursive")
            
        self.run(*args, variables=paths, redirect=False)
        
    def checkin(self):
        os.environ['TFS_IGNORESTDOUTREDIRECT']='1'
        code, output = self.run("checkin")
        return code

class FindCommand(ExternalCommand):
    def __init__(self):
        super(FindCommand, self).__init__("where")

    def find(self, what):
        code, output = self.run(what)
        return output if code == 0 else what
            
class GitExtensions(ExternalCommand):
    def __init__(self, path = None, working_directory = None):
        super(GitExtensions, self).__init__(path or r"c:\Program Files (x86)\GitExtensions\gitex.cmd", working_directory)
        
    def show_commit_dialog(self):
        self.run("commit")

def create_git():
    cmd = FindCommand().find("git")
    git = Git(cmd)
    git.working_directory = git.find_root()
    return git
    
def check_changes(git, branch):
    if git.get_status():
        print "There are uncommited changes in branch %s." % branch
        sys.stdout.flush()
        
        GitExtensions().show_commit_dialog()
        if git.get_status():
            should_continue = tkMessageBox.askyesno(
                "Git TFS", 
                "There are uncommited changes in branch %s.\nDo you want to loose these changes and proceed with operation?" % branch
            )
            if not should_continue:
                print "TFS operation aborted, no changes made"
                return False
                
    return True

def validate_solutions(solutions):
    result = True
    for solution in solutions:
        with open(solution, "rt") as sln:
            if sln.read().find("GlobalSection(TeamFoundationVersionControl) = preSolution") < 0:
                print "ERROR: Solution", solution, "does not have TFS bindings"
                result = False
    return result
    
def validate_csprojects(projects):
    result = True
    for project in projects:
        with open(project, "rt") as csproj:
            if csproj.read().find("<SccProjectName>SAK</SccProjectName>") < 0:
                print "ERROR: Project", project, "does not have TFS bindings"
                result = False
    return result
            
                
def validate(status):
    # Get all the files to be checked in to TFS
    all_files = status.added | status.modified | set(x[1] for x in status.renamed | status.copied)
    
    # Make absolute paths
    to_checkin = [os.path.join(status.base_path, x) for x in all_files]
    
    is_valid = True
    
    if not validate_solutions(x for x in to_checkin if x.lower().endswith(".sln")):
        is_valid = False
        
    if not validate_csprojects(x for x in to_checkin if x.lower().endswith(".csproj")):
        is_valid = False
        
    return is_valid
    
def pull_from_tfs():
    git = create_git()
    
    branch = git.branch_name
    is_on_master = branch == "master"

    if not check_changes(git, branch):
        return 1

    if not is_on_master:
        git.checkout("master", force=True)
        
    git.reset_and_clean()
    
    if not Tfs(working_directory=git.working_directory).get_latest():
        print "No files fetched from TFS, nothing to merge"
    else:
        git.add_all()
        if git.get_status():
            git.commit("Merged from TFS")
        else:
            print "TFS changes are already in git, nothing to merge"

    if not is_on_master:
        git.checkout(branch)
        git.rebase("master")
        
    return 0

def push_to_tfs():
    git = create_git()
    tfs = Tfs(working_directory=git.working_directory)
    
    branch = git.branch_name
    is_on_master = branch == "master"
    if is_on_master:
        print "Current Git branch is master, nothing to do."
        return 1

    if not check_changes(git, branch):
        return 1

    # Clean anything not tracked by git
    git.reset_and_clean()
    
    # Make sure the changes on the branch are based on the current master
    git.rebase("master")
    if not check_changes(git, branch):
        return 1

    git.checkout("master", force=True)

    # Revert all TFS-specific changes that are not tracked by git
    # After this, the working tree should be the same as what is in TFS
    tfs.undo(["."], recursive=True)

    # Clean anything not tracked by git
    git.reset_and_clean()
    
    # Merge squashed so that get_status() can read all changes
    # between branch and master
    git.merge(branch, squash=True)

    status = git.get_status()
    if not status:
        print "No changes detected, switching back to working branch"
        git.checkout(branch)
        git.reset_and_clean()
        return 0
    
    # Make sure that everything seems ok
    print "Validating changes"
    if not validate(status):
        print "Validation failed, neither master branch nor TFS have been modified. Fix the errors and try again."
        git.checkout(branch, force=True)
        git.reset_and_clean()
        return 1
    
    print "Registering changes in TFS"
    
    # Inform TFS about the changes tracked by git
    # The order of operations should not matter, but to be on the safe side
    # we do the non-destructive changes first
    if status.added:
        tfs.add(status.added)
        
    if status.copied:
        tfs.copy(status.copied)

    if status.modified:
        tfs.checkout(status.modified)
    
    # Clean up the merge attempt and bring back old files to allow TFS to rename and delete them
    git.reset_and_clean()
    
    if status.renamed:
        tfs.rename(status.renamed)
        
    if status.deleted:
        tfs.delete(status.deleted)
        
    # Revert all changes caused by TFS
    git.reset_and_clean()
    
    # Finally, get the changes from the branch
    print "Merging changes from", branch, "into master"
    git.merge(branch)
    
    print "Checking into TFS"
    code = tfs.checkin()
    if code == 0:
        print "Changes pushed successfully."
        git.checkout(branch)
        return 0
    elif code == 1:
        print "No TFS-related changes"
        git.checkout(branch)
        return 0
    else:
        print "Merged into Git master branch. You can commit to TFS now."
        return 1
        
    
def create_argument_parser():
    parser = argparse.ArgumentParser(description='Utilities for working with Git and TFS')
    parser.add_argument('action', choices=['pull', 'push'], help='Action to perform: pull changes from TFS, or push them from Git to TFS')
    return parser

if __name__ == '__main__':
    root = Tkinter.Tk()
    root.withdraw()
    
    args = create_argument_parser().parse_args(sys.argv[1:])
    if args.action == 'pull':
        code = pull_from_tfs()
    else:
        code = push_to_tfs()
    sys.exit(code)
    