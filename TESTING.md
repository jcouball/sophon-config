# Testing

How a change to this repo is tested before it merges. This file describes
methods. It does not list test cases: those are in the pull request that made
each change, and the table at the end says which.

Reaching sophon, scratch directories, long jobs and which processes may be
stopped are covered by the owner's own agent instructions, not here.

## Three kinds of test

| Kind | What it finds | When |
| --- | --- | --- |
| A run on sophon, in a scratch directory | Whether the changed script does what it should, and refuses what it should | Every change to a script, a template or a data file a script reads |
| The certification VM | What only a clean machine shows: missing prerequisites, ordering, a prompt nobody answers | A change to the bootstrap path. "Re-certify the rebuild" in the README says which changes those are and how to run it |
| Tests of logic, committed with the code | A wrong answer from parsing or decision code | A change that adds or changes such code. See [Logic](#logic) |

A docs-only change needs none of them.

A pull request does not need a certification run to merge: "Re-certify the
rebuild" in the README says what needs one before it reaches `stable`, the
branch a rebuild clones, and when. `recertify.ps1` certifies `main` unless it
is told otherwise. To try a change in the VM before it merges, name the
branch, once, after review. The run's log and its `result.json` name the
commit and the tree the VM built; put those and the verdict in the pull
request:

```powershell
& "$HOME\.local\bin\recertify.ps1" -Branch <branch>
```

The branch has to be pushed: the VM clones it from GitHub. By hand, the same
thing is `chezmoi init --apply --branch <branch> jcouball/windows-dev-config`.

## Do not

These are limits, not methods. They protect the machine or keep a test
meaningful, and they are not open to a better idea.

- **Do not test a script only under `pwsh`.** chezmoi runs every `.ps1` with
  Windows PowerShell 5.1 (`[interpreters.ps1]` in `.chezmoi.toml.tmpl`), and
  so does mise's hook. Start the script with `powershell`. Script 14 is the
  one script that restarts itself under pwsh 7; start it with `powershell`
  too, so the restart is part of the test.
- **Do not apply a scratch source to the real home directory.** Scripts 01
  and 11 have the source directory's path in their text, so from another
  source directory chezmoi sees them as changed and runs both again: every
  winget package and the OpenSSH server.
- **Do not leave sophon changed.** When a test has to change the machine, say
  so in the pull request, and put back what it changed.
- **Do not leave out what was not tested.** Say it in the pull request, with
  the reason.

## Working habits

- **Test what chezmoi would run.** A `.tmpl` file is not a script until it is
  rendered. Render it, and run the result.
- **Put test code in a file and copy it over.** A command of any length quoted
  through ssh, PowerShell and bash at once does not survive. Write the `.ps1`
  or `.sh` locally, `scp` it to the scratch directory, and run it with
  `-File`.
- **Check outcomes, not exit codes.** Read back the file, the registry value
  or the program's own report of its version.

## Getting a branch onto sophon

The chezmoi source on sophon is `C:\Users\james\.local\share\chezmoi`, on
`main`. Do not switch it to a branch for a test unless the test is of
`chezmoi apply` itself; see [A real apply](#a-real-apply).

Clone it into the scratch directory and put the change on top:

```powershell
git clone -q C:\Users\james\.local\share\chezmoi src
git -C src apply ..\change.patch
```

`change.patch` is `git diff origin/main` from the working clone. Run
`git add -N` on a new file first, or the diff leaves it out. A git bundle
fetched into the clone does the same job for a branch with several commits.

## Running a script from the branch

**A rendered script run as it is acts on the real machine.** It is the script
chezmoi would run, with the real paths in it. Before running one, point
everything it changes at a scratch copy. The whole sequence, for script 14,
which changes one file:

```powershell
# 1. Render the template against the scratch source.
$rendered = (chezmoi execute-template --source "$PWD\src" --file src\.chezmoiscripts\run_onchange_after_14_terminal_font.ps1.tmpl) -join "`n"

# 2. Replace the assignment of the path it changes with a read of an
#    environment variable. Fail if the replacement did not happen, or the
#    script would run against the real file.
$pattern = '(?s)\$settings = Join-Path \$env:LOCALAPPDATA `\s*''[^'']+'''
if ($rendered -notmatch $pattern) { throw 'could not find the $settings assignment' }
$script = [regex]::Replace($rendered, $pattern, '$settings = $env:TEST_SETTINGS')

# 3. Write the changed script, and run that one.
[IO.File]::WriteAllText("$PWD\under-test.ps1", $script)
$env:TEST_SETTINGS = "$PWD\case.json"
powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File under-test.ps1
```

Read the script first and find every place it writes: a file, a registry key,
a service, the user `PATH`, the session. Each one needs a replacement like
step 2. A script whose targets cannot all be pointed elsewhere, as script 13
writes to the registry and to the session, is not tested this way. Test it on
the certification VM, or as [A real apply](#a-real-apply) with what that
section asks for.

Rendering itself is safe, and it reads this machine: scripts 05 and 14 take a
hash of Windows Terminal's real `settings.json`, so the rendered text changes
whenever that file does.

The same trick makes a failure happen on purpose: a second copy of the script
with a line inserted, or a path broken, at the point being tested. Say in the
pull request which lines were changed for the test.

A script that already takes its paths as parameters needs none of this:

| Script | How to run it without touching the machine |
| --- | --- |
| `ruby-toolchains.ps1` | `-Root <scratch>` builds toolchains there, with a cache of its own. `-NoLink` leaves every Ruby alone. `-RubyRoot <scratch>` links copies of Rubies instead of mise's. `-LinkOnly` downloads nothing. It runs the `ruby-toolchains-packages.sh` in its own folder, so copy the branch's helper from the scratch source to sit beside the rendered worker, or the build uses whatever helper is there, or none |
| `ruby-toolchains-packages.sh` | Its arguments are the day, a cache directory and the packages. Run it inside a scratch toolchain with an empty cache directory: pacman finds every package installed and changes nothing, and the helper's own work is all exercised. `RUBY_TOOLCHAIN_ARCHIVE` takes a `file://` folder, so a copy of a set made for the test needs no upload |
| `ruby-toolchains-archive.ps1` | `-OutDir <scratch>`. It only reads the cache |

A full build of the three toolchains in a scratch root takes about six
minutes and 3 GB.

A toolchain that already has its packages hides what a new one would show:
pacman has nothing to install, so a set with a package missing looks whole.
For that, unpack the base archive from the cache into the scratch directory
and start its shell once. That gives an MSYS2 with no UCRT64 packages in
about a minute:

```powershell
& "$HOME\.local\opt\msys2\cache\msys2-base-x86_64-<version>.sfx.exe" -y "-o$PWD\fresh"
& .\fresh\msys64\usr\bin\bash.exe -lc true
```

## Files and externals

To test what chezmoi writes, as opposed to what a script does, apply the
scratch source to a scratch destination, with scripts left out and a state
file of its own:

```powershell
chezmoi apply --source "$PWD\src" --destination "$PWD\dest" --persistent-state "$PWD\state.boltdb" --exclude scripts
```

Apply everything, not one target: chezmoi does not create the parent folders
of a single target in an empty destination.

## A real apply

Some things only `chezmoi apply` shows: that a failed script is run again by
the next apply, that a `run_onchange` hash changes when it should, the order
scripts run in. For those, switch the real source to the branch, apply, and
put it back:

```powershell
chezmoi git -- fetch origin <branch>
chezmoi git -- switch --detach FETCH_HEAD
chezmoi apply
chezmoi git -- switch main
chezmoi apply
```

This changes sophon, and the last two lines do not change it back. They put
the source and the managed files back, and an empty `chezmoi status` shows
only that. What the branch's scripts did stays done: a package that was
installed, a registry value, a service, a `PATH` entry. Removing a line from
the winget manifest, for one, never uninstalls the package.

So, before the apply, read the scripts that will run and write down what each
will change outside the managed files, and how to undo it. Afterwards undo
each one and check that it is undone, not only that `chezmoi status` is empty.
List what was changed and what was undone in the pull request. If something
the branch does cannot be undone, do not apply it to sophon: test it on the
certification VM.

Do this only when the scratch methods cannot answer the question.

## What an ssh session cannot test

Check these at sophon's desktop, or ask the owner to and say in the pull
request that it was not done:

- **Anything in the desktop session:** a font becoming available to running
  applications, a window opening, Windows Terminal reloading its settings.
- **A script started by pwsh 7.** At the desktop chezmoi is usually started
  from pwsh 7, and the Windows PowerShell it starts inherits pwsh's module
  path. Two applies failed that way, on `Get-FileHash` and `Get-Acl`, after
  passing over ssh.
- **The MSIX build of pwsh.** An ssh session cannot start it ("Access is
  denied"). Over ssh, `pwsh` is the ZIP build in `~\.local\opt`.
- **A link or file made without administrator rights.** An ssh session to
  sophon is an administrator login.

## What to cover

For a script that changes something:

- the change is made, and a second run changes nothing
- each way of not doing it: the script says why, has changed nothing, and
  exits with the right code
- the case a fresh machine is in, where the thing to change does not exist yet

The right code depends on what will make the script run again. chezmoi
records a `run_onchange` or `run_once` script as done when it exits 0, and
runs a `run_onchange` script again only when its rendered text changes.

- **Work that failed, and should be tried again as things are, exits
  non-zero.** chezmoi then runs the script on the next apply. A failure that
  exits 0 is recorded as done and is not tried again.
- **Work put off until something else exists may exit 0, if the script's text
  depends on that thing.** Scripts 05 and 14 exit 0 when Windows Terminal's
  `settings.json` does not exist yet. Both carry a hash of that file, so they
  run again on the first apply after it appears. For such a case, test the
  later run too: that the hash changes, and that the script then does its
  work. A `run_once` script has no such second chance.

## Logic

When a change adds or changes parsing or decision logic, put that logic in a
function a test can call, and commit tests for it with the change. Code that
only changes machine state is tested on sophon as above, with the cases and
results in the pull request.

Committed tests are in `tests` at the root of the repository, which
`.chezmoiignore` keeps off the machine. Each is a plain PowerShell script named
`<script>.tests.ps1` that prints `ok` or `FAIL` for each case and exits 1 if
any failed. They use no test framework: the Pester on sophon is 3.4, for
Windows PowerShell only.

A test builds what the script needs in a temporary folder and points the
script at it, so it reaches nothing outside that folder. `record.tests.ps1`
makes a bare repository to stand for GitHub, a clone of it to stand for the
chezmoi source, a folder of runs, and a stand-in for the checks. `record.ps1`
takes parameters for those places, and says in its `param` block that they are
for the tests.

Run a test under both PowerShells, elevated where the script it tests asks for
that, from a scratch copy of the branch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\tests\record.tests.ps1
pwsh       -NoProfile -File src\tests\record.tests.ps1
```

Put the counts in the pull request. A change to a script that has tests adds
or changes cases with it.

## Where each script's cases are

Each pull request's description lists the cases that were run and what each
gave. Read it before changing the script, and run those cases again.

| Script | Pull requests |
| --- | --- |
| 04 `mise_install`, `mise-path.ps1`, the profile | #12 |
| 05 `terminal_default_profile` | #7 |
| 06 `ruby_toolchains`, `ruby-toolchains.ps1`, `ruby-toolchains-packages.sh` | #9, #21 |
| 08 `git_unix_tools_path` | #6 |
| 11 `openssh_server`, `sshd-pwsh-drift.ps1` | #1 |
| 12 `winget_pin_edge` | #2, #9 |
| 13 `register_fonts`, 14 `terminal_font` | #15 |
| `recertify.ps1`, `recertify-step.ps1`, `recertify-checks.ps1` | #25 |
| `record.ps1` | `tests\record.tests.ps1` |
| The rebuild as a whole | "Certification" in the README |

## Departing from this file

The methods here are the ones that have worked so far, not the only ones
allowed. If another method tests a change better, use it, and in the same
pull request describe it here with the reason the existing method did not fit.
The limits under [Do not](#do-not) are not methods and are not open to this.

When a pull request tests a script, add its number to the table above.
