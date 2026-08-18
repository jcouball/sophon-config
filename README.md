# sophon-config

Configuration for **sophon**, a Windows 11 Pro workstation used mainly for JRuby
development. Managed with [chezmoi](https://chezmoi.io).

Companion to [jcouball/dotfiles](https://github.com/jcouball/dotfiles) (macOS).
This repo is scoped to one machine deliberately: no OS templating, every file is
simply the file. The cost is that `.gitconfig`, `.tool-versions` and
`topgrade.toml` now exist in two repos and will drift; the benefit is that
nothing here needs a conditional.

| | |
| --- | --- |
| Host | sophon — Windows 11 Pro, build 26200 |
| Shell | PowerShell 7 (`pwsh`) |
| Terminal | Windows Terminal (managed) · Warp (by hand) |
| Package manager | winget 1.29 |
| Runtimes | mise, 7 tools |
| WSL | 2.5.10 (Ubuntu 24.04.3, deliberately bare) |
| Rebuild | **certified** on a clean VM |

---

## Contents

- **Do something**
  - [Rebuild from nothing](#rebuild-from-nothing) — the emergency procedure
  - [Playbooks](#playbooks) — everyday tasks, grouped by the layer that owns them
- **Understand it**
  - [System tools vs project runtimes](#system-tools-vs-project-runtimes)
  - [The stack](#the-stack) — the layers, and who owns what
  - [Repository layout](#repository-layout) — every file, and two path traps
  - [Which shell](#which-shell)
  - [Recreating this repo from scratch](#recreating-this-repo-from-scratch) — not the machine
  - [How often to run what](#how-often-to-run-what)
- **Why it is the way it is**
  - [Ownership decisions](#ownership-decisions)
  - [Native JRuby development](#native-jruby-development)
  - [Certification](#certification) — eleven defects a clean machine found
  - [Secrets](#secrets)
  - [Deliberately not managed](#deliberately-not-managed)
  - [Small gotchas](#small-gotchas)

---

## Rebuild from nothing

**The emergency procedure.** Neither detail below is optional — both were found
the hard way on a clean VM, and without them the very first step fails.

```powershell
# normal terminal
# --source winget is required: a fresh Windows image's msstore source fails its
# certificate check, and winget then refuses to auto-select a source
winget install twpayne.chezmoi --source winget

# NEW ELEVATED terminal - PATH is stale in the old one, and the manifest
# contains machine-scope packages that stall silently without elevation
chezmoi init --apply jcouball/sophon-config
```

This path is **certified** — run end to end on a clean Windows 11 Enterprise
25H2 VM as a different user. See [Certification](#certification) for what that
found.

Afterwards, by hand: Warp if you want it, and Warp's own settings, which cannot
be versioned.

---

## Playbooks

The rule underlying all of them: **the repo must never lag the machine.**
Whenever you install, remove or re-pin something, the corresponding file goes
back into the repo in the same sitting.

### Layer 2 — applications and core tools

#### Install an application

```powershell
winget install <id>
winget export -o (chezmoi source-path)\winget-packages.json
chezmoi cd; git commit -am "Add <id>"; git push
```

Then strip the deliberate exclusions, which `winget export` keeps re-adding — the
snippet is in the header of `run_onchange_01_winget_install.ps1.tmpl`. Currently
excluded: **`Warp.Warp`**, whose installer takes an extraordinarily long time and
opens a welcome window mid-provisioning. Install it by hand when wanted.

#### Uninstall an application

```powershell
winget uninstall --id <id> --exact --purge
winget export -o (chezmoi source-path)\winget-packages.json
chezmoi cd; git commit -am "Remove <id>"; git push
```

The manifest has **no cleanup semantics**. Deleting a line never uninstalls
anything; it only stops a rebuild reinstalling it.

#### Hold a version back

```powershell
winget pin add --id <id>
winget pin list
winget pin remove --id <id>
```

### Layer 3 — language runtimes

#### Upgrade a language version

```powershell
mise use -g ruby@4.0.7
chezmoi re-add ~/.config/mise/config.toml
chezmoi cd; git commit -am "ruby 4.0.6 -> 4.0.7"; git push
```

`mise use -g` rewrites `config.toml`, so that file must go back to the repo — it
is the declaration a rebuild replays.

Changing `config.toml` re-triggers script 06 as well as script 04. For a **Ruby**
bump that is the point — the new install has no compiler until it runs — but it
means the apply that installs Ruby 4.0.7 also spends several minutes and about a
gigabyte fetching the toolchain again. See
[Ruby native extensions](#ruby-native-extensions--the-toolchain-lives-inside-the-ruby).

#### Add a new runtime

```powershell
mise registry | Select-String deno
mise use -g deno@2.5.1
chezmoi re-add ~/.config/mise/config.toml
```

#### Pin a runtime for one project

```powershell
cd ~/src/my-project
mise use node@26.5.0
mise install
```

No `-g`. That file belongs to the *project's* repo, never to sophon-config.

#### Retire a runtime

```powershell
mise uninstall ruby@4.0.6
mise unuse -g ruby
chezmoi re-add ~/.config/mise/config.toml
```

### Layer 4 and the editor

#### Install a global CLI tool

```powershell
npm i -g prettier markdownlint-cli
uv tool install yamllint
```

These live *inside* the runtime mise installed, so re-pinning that runtime loses
them. Record anything you would miss in `~/.default-npm-packages`.

#### Install a VS Code extension

```powershell
code --install-extension <publisher.name>
code --list-extensions
```

**Settings Sync owns these** — install normally and it propagates to the Mac.
Do *not* also keep an extension list here; running both produces conflicts with
no arbiter.

#### Install a tool neither manager has

Do **not** hand-extract to `C:\Tools` — that is how Ant became invisible to every
inventory and was nearly deleted as vestigial. Use a chezmoi external:

```toml
# .chezmoiexternal.toml
[".local/opt/thing"]
    type = "archive"
    url = "https://example.com/thing.zip"
    stripComponents = 1
```

### chezmoi

#### Change a managed config

```powershell
chezmoi re-add ~/.config/powershell/profile.ps1
# or, from the source side:
chezmoi edit ~/.config/powershell/profile.ps1 --apply
```

#### Start managing a new file

```powershell
chezmoi add ~/.gitconfig
chezmoi cd; git commit -am "Manage gitconfig"
```

Never a path inside OneDrive or any synced folder — use a stub that sources an
unsynced file instead.

#### Stop managing a file

```powershell
chezmoi forget ~/.some-file
```

`forget` drops it from the repo and leaves your copy alone. `destroy` deletes
both — be sure.

#### Update everything

```powershell
topgrade --dry-run
topgrade
```

#### Find out what drifted

```powershell
chezmoi status
chezmoi diff
```

#### Pull changes made elsewhere

```powershell
chezmoi update --dry-run
chezmoi update
```

### Re-certify the rebuild

Do this after **any change to the bootstrap path**: a new or edited provisioning
script, a new package manager, a change to `.chezmoi.toml.tmpl`, or a managed
file whose location depends on the machine. Not needed for adding a package or
bumping a runtime — those exercise proven ground.

```powershell
# on the host, ELEVATED - every Hyper-V cmdlet needs it, and unelevated they
# return empty lists rather than errors
Restore-VMCheckpoint -VMName sophon-cert -Name 'clean-windows' -Confirm:$false
vmconnect.exe localhost sophon-cert
```

Then run the [rebuild](#rebuild-from-nothing) **unmodified** — the point is to
test what this README says, not a convenient variant — wrapped in a transcript,
because without a log the failures have to be inferred from wreckage:

```powershell
Start-Transcript -Path "$HOME\bootstrap.log"
chezmoi init --apply jcouball/sophon-config
Stop-Transcript
```

Verify **outcomes, not exit codes**. A script returning zero has proved nothing:

```powershell
mise ls --current          # 7 tools, none "(missing)"
Test-Path 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC'
$env:JAVA_HOME             # populated, in a NEW shell
chezmoi status             # empty
```

See [Certification](#certification) for why this exists and what it found.

---

## System tools vs project runtimes

> I use Topgrade to manage overall system and core tools, not the dependencies
> for individual software projects. This prevents a global update from
> accidentally breaking a project that depends on specific package versions.
>
> — from the macOS `topgrade.toml`

**System and core tools** can be swept forward in bulk. **Project runtimes** are
pinned, and are never upgraded by a command that also upgrades your browser.
When adding something new, that question decides which layer owns it.

### Why `sophon-config` and not `dotfiles`

"dotfiles" is a Unix idiom. On Windows most of what is managed lives in
`%APPDATA%` and `%LOCALAPPDATA%` — very little of it is dot-prefixed, so the name
would misdescribe the contents. `sophon-config` leads with the scope (the
machine) and stays tool-agnostic, so it survives if chezmoi is ever replaced.

---

## The stack

| Layer | Tool | Owns |
| --- | --- | --- |
| 0 | git + gh | **Transport.** If a setting exists only on the machine and not here, it is not managed and will be lost. |
| 1 | **chezmoi** | **Declaration and orchestrator.** Config file contents, and the manifest of what should be installed. Its scripts call the layers below; it installs nothing itself. |
| 2 | **winget** | **Applications and stable CLI tools.** Git, VS Code, Chrome, 1Password, Docker, `gh`, `jq`, `rg`, chezmoi itself. Driven from `winget-packages.json`. |
| 3 | **mise** | **All seven runtimes and build tools** — ant, go, java, node, python, ruby, rust. Pinned exactly; never swept. |
| 4 | npm · uv · gem · cargo | **Libraries and runtime-scoped tools.** `prettier`, `yamllint`, `@github/copilot`. Subordinate to layer 3. |
| 5 | **topgrade** | **Owns nothing.** Dispatches layers 2 and 4 plus Windows Update, VS Code, gh extensions and chezmoi. |
| 6 | WSL | **Escape hatch** for POSIX-only tooling — `skopeo`, `redis`, `htop`, GNU autotools. Separate machine, separate management. |

`mise activate pwsh` exports `JAVA_HOME`, `ANT_HOME`, `GOROOT`, `CARGO_HOME` and
`RUSTUP_HOME` — not just `PATH`. That is what lets it own the JDK, which `mvnw`
requires. Activation works in Windows PowerShell 5.1 too; only mise's `chpwd`
hook, and therefore per-directory switching, needs pwsh 7.

### How the layers call each other

```text
        github.com/jcouball/sophon-config
                       │
                       │  chezmoi update
                       ▼
                    chezmoi                 renders files, runs scripts
                       │
                       │  scripts invoke
          ┌────────────┼────────────┐
          ▼            ▼            ▼
        winget        mise       npm · uv
      apps & CLI    runtimes     libraries
          ▲            ▲            ▲
          └────────────┼────────────┘
                       │
                    topgrade                updates, never installs
```

Top-down is **provisioning**. Bottom-up is **maintenance**. The rule that keeps
it coherent: **topgrade never introduces anything new.** If a tool appears on
this machine that isn't in the repo, the system has a hole in it.

### Ownership rules

| Situation | Owner | Recorded in |
| --- | --- | --- |
| GUI app or stable CLI tool | winget | `winget-packages.json` |
| Language runtime, version matters | mise | `dot_config/mise/config.toml` |
| Library inside a runtime | npm / uv / gem | `.default-npm-packages` etc. |
| Config file contents | chezmoi | the `dot_*` file itself |
| POSIX-only, no native build | WSL | WSL's own setup |

---

## Repository layout

```text
README.md                             this document (ignored, not deployed)
.chezmoi.toml.tmpl                    PowerShell interpreter, -ExecutionPolicy Bypass
.chezmoiignore                        keeps README and the manifest source-only
.gitattributes                        * text=auto eol=lf
winget-packages.json                  32 packages; read by script 01, never deployed

dot_config/powershell/profile.ps1     mise activation; the real profile
dot_config/husky/init.sh              git hooks get mise on PATH
dot_config/mise/config.toml           the seven pinned runtimes
AppData/Roaming/topgrade.toml         update policy - NOT dot_config, see below

.chezmoiscripts/
  run_onchange_01_winget_install.ps1.tmpl          winget import
  run_once_02_powershell_execution_policy.ps1      let 5.1 load the stubs at all
  run_once_02_powershell_profile_stubs.ps1         stubs at $PROFILE, wherever that is
  run_once_03_build_tools.ps1                      VS Build Tools C++ workload
  run_onchange_after_04_mise_install.ps1.tmpl      materialise the runtimes
  run_once_after_05_terminal_default_profile.ps1   point Terminal at pwsh 7
  run_onchange_after_06_ruby_devkit.ps1.tmpl       MSYS2 toolchain for native gems
  run_once_after_07_mise_shims_path.ps1            shims on user PATH, for cmd.exe
```

Two scripts share the number `02` because they are one job: making PowerShell
actually load the managed profile. Writing a stub a shell refuses to execute
accomplishes nothing. They sort in the order they need to run — `e` before `p`.

### Two path traps

**`topgrade.toml` lives at `%APPDATA%`, not `~/.config`.** On macOS it's the Unix
location; on Windows it is not. Put it in the Unix location and it is silently
inert. `topgrade --dry-run` catches this — if steps you excluded still appear,
the config isn't being read.

**Anything in the source root without a leading dot becomes a target.**
`README.md` and `winget-packages.json` would be written to the home directory;
both are in `.chezmoiignore`. Dot-prefixed source files are ignored by chezmoi
automatically, which is why real dotfiles need the `dot_` prefix.

### The `after_` attribute is required, not stylistic

Targets are applied in lexicographic order, and `.chezmoiscripts/` sorts before
`.config/` — `.ch` precedes `.co`. Any script depending on a chezmoi-managed
file must use `run_..._after_`, or it runs before that file exists. See
[Certification](#certification) for what that cost.

---

## Which shell

Keep the two ideas separate: the **terminal** is the window, the **shell** is
what runs in it.

**Windows Terminal is the managed terminal.** It comes from the manifest, and
script 05 points its `defaultProfile` at pwsh 7 — so a rebuilt machine lands in
the right shell with no manual step.

**Warp is a personal preference, installed by hand.** It is deliberately
excluded from the manifest (its installer is extremely slow and opens a welcome
window mid-provisioning), so a rebuild will not have it. Install it whenever you
want it, and set its default shell to pwsh in its own settings:

```powershell
winget install Warp.Warp --source winget
```

Warp's shell preference cannot be scripted — see
[Deliberately not managed](#deliberately-not-managed).

| Shell | Use it for |
| --- | --- |
| **PowerShell 7** (`pwsh`) | **Primary.** Everything here. `winget install Microsoft.PowerShell` |
| Windows PowerShell 5.1 | Avoid. `&&` and `\|\|` are parser errors, `Set-Content` defaults to ANSI rather than UTF-8, and a native command's stderr sets `$?` false even on a clean exit — which misfires constantly around `git` and `winget`. |
| Git Bash | POSIX scripts carried from the Mac. Also what runs git hooks — see `dot_config/husky/init.sh`. |
| WSL | Genuinely Linux work. |
| cmd.exe | Never. |

### How the managed tools reach a shell

Two mechanisms, and knowing which one is carrying a given shell is the
difference between a five-minute diagnosis and an hour of it.

**`mise activate`, from the PowerShell profile.** The primary path. It injects
the tool directories into `PATH` *and* exports `JAVA_HOME`, `ANT_HOME`,
`GOROOT`, `CARGO_HOME` and `RUSTUP_HOME`. The JRuby build reads the first two,
so this is not optional and cannot be replaced by shims. PowerShell only.

**`%LOCALAPPDATA%\mise\shims` on the persisted user `PATH`.** Added by script
07. Real `.exe` files that re-dispatch through mise, so anything that reads
`PATH` finds them — cmd.exe, a 5.1 window whose policy is locked down, a GUI app
launched from Explorer. It resolves tools; it exports nothing.

| Shell | Tools via | Why |
| --- | --- | --- |
| pwsh 7 | activation, plus shims | Profile loads; policy is `RemoteSigned` from a `powershell.config.json` inside its install directory |
| Windows PowerShell 5.1 | activation, plus shims | Only since script 02 set `CurrentUser` to `RemoteSigned`. Before that the stub was refused and the shell had nothing |
| cmd.exe | shims only | mise has **no** cmd.exe activation. There is no hook to install. Shims are the only route |
| Git Bash | shims, prepended by `init.sh` | Only for git hooks, and only inside them. `mise activate bash` emits a Windows-form `;`-separated `PATH` that shreds a POSIX one — see `dot_config/husky/init.sh`. An interactive Git Bash still has neither |

The failure this fixed: `ruby` and `irb` were "not recognized" in both cmd.exe
and Windows PowerShell 5.1, for two unrelated reasons that presented
identically. 5.1 was refusing the profile stub under the default `Restricted`
policy — which is per-edition, so pwsh 7 was unaffected and hid it. cmd.exe was
never covered at all. Watch for `PSExecutionPolicyPreference` when diagnosing
this: an `-ExecutionPolicy Bypass` parent sets it, child processes inherit it,
and both editions then report a policy the real shell does not have.

### Documents is redirected to OneDrive

`$PROFILE` resolves under `C:\Users\james\OneDrive\Documents\...`. **chezmoi must
never manage a file inside a synced folder** — both tools write the path
independently and produce `-SOPHON.ps1` conflict copies with no winner.

The arrangement: chezmoi owns `~/.config/powershell/profile.ps1`, and one-line
stubs at `$PROFILE` source it. The stubs never change, so OneDrive has nothing
to conflict over. Script 02 writes them by asking each PowerShell edition for
`$PROFILE.CurrentUserCurrentHost` rather than constructing a path — which is
what makes the same code correct here and on a machine with no redirection.

---

## Recreating this repo from scratch

Only needed to recreate this repo from scratch; a rebuild uses the two commands
at the top.

1. **Install the shell.** `winget install Microsoft.PowerShell --source winget`.
   No terminal configuration needed yet — Windows Terminal ships with Windows and
   script 05 sets its default profile later. Warp, if wanted, is a hand install
   at the end.
2. **Install chezmoi and gh.**
   `winget install twpayne.chezmoi GitHub.cli --source winget`, then
   `gh auth login`. Neither will be on `PATH` in an already-running process —
   restart the terminal, or in VS Code restart the editor, since new terminal
   tabs inherit the editor's stale environment.
3. **Create the repo.** `gh repo create jcouball/sophon-config --private`
4. **Initialise.** `chezmoi init jcouball/sophon-config`
5. **Set line endings before the first commit.**
   `chezmoi cd`, then
   `Set-Content -Path .gitattributes -Value '* text=auto eol=lf' -Encoding utf8`
6. **Capture the package set.**
   `winget export -o (chezmoi source-path)\winget-packages.json`
7. **Add configs.** `chezmoi add ~/.gitconfig` etc.
8. **Wire the profile via stubs**, never directly — see [Which shell](#which-shell).
9. **Write `topgrade.toml` at `%APPDATA%`** — see the warning below.
10. **Review, then apply.** `chezmoi diff`, then `chezmoi apply -v`
11. **Push.** `chezmoi cd; git add -A; git commit; git push -u origin main`

---

## How often to run what

| When | Command | Why |
| --- | --- | --- |
| Immediately after editing any config by hand | `chezmoi re-add` | The single habit that makes this work. Skip it once and the repo starts lying to you. |
| Weekly | `topgrade` | Sweeps winget, VS Code, gh extensions, Windows Update, and pulls the repo. |
| Weekly, before topgrade | `chezmoi status` | Catches files changed on disk that never made it back. |
| When adding a tool | `winget install` then `winget export` | Install, then re-snapshot. Commit both together. |
| Per project | `mise install` | Runtimes are project-scoped. Never on a schedule. |
| Monthly, or never | `chezmoi verify` | Optional audit that every managed file matches its declared state. |

**Run bulk upgrades from an elevated terminal, with Warp and Teams closed.** A
non-elevated run gets partway and then blocks invisibly on an elevation prompt it
cannot display: no output, no error, zero CPU. Packages that update themselves
(`Microsoft.AppInstaller`, `Warp`) cannot be upgraded while running.

Nothing needs holding back any more — the JDK and Ruby both left winget for mise,
so `winget upgrade --all` no longer touches anything a build depends on. The
version discipline moved to layer 3, and topgrade's `only` list excludes mise
precisely so a weekly sweep cannot reach it.

---

## Ownership decisions

### Everything runtime-shaped belongs to mise, natively on Windows

Settled by measurement. Three claims made along the way turned out to be wrong
and are recorded so the reasoning is not repeated:

- **"mise can't install Ruby natively — ruby-build is POSIX."** Wrong. On Windows
  mise installs from **RubyInstaller2**. `gem env home` lands correctly inside
  the mise install.
- **"mise on Windows is shims-only, so no `JAVA_HOME`."** Outdated — that line is
  from the FAQ. `mise activate pwsh` is documented and exports the full
  environment.
- **"Ant in `C:\Tools` is probably vestigial."** Wrong, and the failure would have
  been silent: JRuby's bundled `rake/ant` resolves `ANT_HOME` or falls back to
  `ant` on `PATH`, and `rakelib/commands.rake` swallows the failure with a
  `warn`.

Verified end to end: `mvnw -v` reports
`runtime: ...\mise\installs\java\zulu-21.52.15.0`.

RubyInstaller and the winget-installed Zulu were both removed; `C:\Tools` is
gone.

### Rust linker — MSVC, via winget

rustup installs the msvc toolchain by default but there were no Build Tools on
the machine, so anything with native code failed at link time. MSVC over the gnu
toolchain because `Microsoft.VisualStudio.2022.BuildTools` is a winget package —
layer 2 owns it and a rebuild reproduces it. The gnu alternative would need
`rustup set default-host`, whose state lives in `~/.rustup/settings.toml` and is
captured by neither mise nor the manifest.

`winget export` **does** record `InitialOverrideArguments`, but `winget import`
does **not** apply them — the data survives the round-trip, the effect does not.
Script 03 exists for that, and needs `--force` because a plain `winget install`
against an already-installed package answers "no available upgrade" and skips
the override entirely.

### Ruby native extensions — the toolchain lives inside the Ruby

mise installs Ruby from RubyInstaller2, but the bare build, with no compiler. The
symptom is a `bundle install` where *every* native gem fails identically —
`The compiler failed to generate an executable file` — which reads like a broken
Ruby rather than a missing toolchain. `ridk install 1 3` fixes it; script 06 runs
that.

The part worth recording is **where it installs**, because the obvious assumption
is wrong and it is wrong quietly. It is not `C:\msys64`, and it is not shared.
RubyInstaller's installer component hardcodes its root:

```ruby
run_verbose(downloaded_path, "install", "--root",
            File.join(RbConfig::TOPDIR, "msys64"), ...)
  # site_ruby/<ver>/ruby_installer/runtime/components/01_msys2.rb
```

and `RbConfig::TOPDIR` for a mise-managed Ruby is the *versioned* install
directory — `...\mise\installs\ruby\4.0.6`. So the toolchain lives inside the
Ruby that mise owns, and a version bump leaves it behind. This is why script 06
is `run_onchange` on `config.toml` and not `run_once`: `run_once` would fix this
machine today and let the next Ruby bump silently break native gems again.

Contrast with the Rust linker above, which is genuinely machine-level and
therefore belongs to winget. A shared MSYS2 would work here too —
`iterate_msys_paths` searches `C:/msys64` and the directory beside `TOPDIR` — but
putting one there means either adding `MSYS2.MSYS2` to the manifest or
reimplementing component 1's pinned download, and neither is worth displacing
ridk's own supported path. The accepted cost is the re-download on a Ruby bump.

### Git hooks — husky's `init.sh`

Hooks run under Git for Windows' `sh.exe` and never see the PowerShell profile.
Fired from a terminal they inherit an activated environment and work; fired from
a GUI client (VS Code's Source Control panel, GitButler) they do not, and fail
with `npx: command not found` on the same commit. `~/.config/husky/init.sh` is
husky's documented hook for exactly this. Must stay LF-only.

### Accepted exceptions — not drift

**Brother PowerENGAGE** and the **Google Gemini** PWA registration stay,
unmanaged and deliberately so. The printer utility is tied to hardware; the
Gemini entry is a Chrome shortcut, not an application.

---

## Native JRuby development

JRuby is debugged and built **natively on Windows**, from `C:\Users\james\jruby`,
against mise's Zulu 21 via the repo's own `mvnw.cmd`. WSL is not in this path.

| What | Fix |
| --- | --- |
| **Windows long paths** — `core.longpaths=true` covers git, but Maven and the JDK hit `MAX_PATH` independently | `Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name LongPathsEnabled -Value 1` (admin, reboot) |
| **Defender exclusions** — Maven is I/O-heavy and real-time scanning taxes every rebuild | `Add-MpPreference -ExclusionPath 'C:\Users\james\jruby', "$HOME\.m2"` |
| **VS Code Java tooling** — debugging JRuby means stepping through Java | `code --install-extension vscjava.vscode-java-pack` |
| **git line endings** — already correct, leave alone | `core.autocrlf=false`, `core.symlinks=false` |

The pom pins `base.java.version 21`. There is no MRI dependency — JRuby
bootstraps with its own `bin/jruby`.

---

## Certification

A clean `chezmoi diff` proves the repo describes this machine. It says nothing
about whether the repo can *produce* one. So the rebuild was run against a
throwaway Hyper-V VM — Windows 11 Enterprise 25H2, build 26200, user `certuser`.

**Eleven defects surfaced. Every one was invisible on sophon**, and all sat in
the recovery path you would only exercise under pressure.

| Defect | Why sophon masked it |
| --- | --- |
| `winget install` fails without `--source winget` | sophon's `msstore` source is healthy |
| `ExecutionPolicy=Restricted` blocks every script | sophon is `RemoteSigned` |
| Profile stub path hardcoded to OneDrive | sophon's Documents *is* redirected there, so the wrong assumption was accidentally correct |
| Scripts ordered before the tools they use | everything already installed |
| No `PATH` refresh for same-run installs | mise and pwsh already on `PATH` |
| `winget import` ignores `InitialOverrideArguments` | Build Tools installed by hand, with workload |
| `winget install` silently no-ops on installed packages | never exercised |
| Build Tools script hit the msstore failure too | as above |
| **Script 04 ran before its own config file existed** | config already on disk |
| Windows Terminal rewrites its `settings.json` | corrosive only over time |
| Warp's installer is very slow and opens a window | tolerable interactively |

Three were caught by *reasoning* about a machine that wasn't sophon — asking what
would happen to a user named `certuser` — before the VM ran at all. The other
eight needed a real clean machine. Three revert-and-retry cycles to a clean run.

### The one that justifies the exercise

Script 04 ran before chezmoi had written `~/.config/mise/config.toml`, because
`.chezmoiscripts/` sorts before `.config/`. mise read no configuration, found
nothing to install, and reported **"all tools are installed"**. Which was true,
and meant nothing.

The run finished clean. No error, no warning, no missing step. A rebuild would
have looked completely successful and left the machine with no Java, no Ruby and
no Ant — discovered whenever JRuby was next built. Every other failure announced
itself. This one reported success. The fix is the `after_` attribute.

### The certification VM

Hyper-V, Generation 2, 8 GB / 4 vCPU / 80 GB dynamic. Windows 11 requires TPM
2.0, so `Set-VMKeyProtector -NewLocalKeyProtector` must run **before**
`Enable-VMTPM`. Secure Boot uses the `MicrosoftWindows` template. Standard
checkpoints (they capture memory, so a revert restores exactly); automatic
checkpoints disabled.

Two traps: connect with `vmconnect` **before** starting the VM, or the
"press any key to boot from CD" prompt expires and you land at
"No operating system was loaded". And every Hyper-V cmdlet needs elevation —
unelevated they return *empty lists* rather than access-denied, so a checkpoint
can appear not to exist when it does.

### Running it again

The procedure lives with the other procedures:
**[Re-certify the rebuild](#re-certify-the-rebuild)**. Keep the VM and its
`clean-windows` checkpoint — reverting costs seconds, rebuilding that
environment costs an hour.

---

## Secrets

This repo is **public**. A value committed and deleted in the next commit is
still in the history, in every clone, and in GitHub's API. Rotation is the only
remedy.

| Situation | Mechanism |
| --- | --- |
| Mostly-public file, one secret field | **1Password at render time.** The template holds a reference; the value is fetched on apply. `{{ onepasswordRead "op://Private/npm/token" }}` |
| Whole file is secret | **age encryption.** `chezmoi add --encrypt ~/.gem/credentials` |
| SSH private keys, signing keys | **Don't manage it at all.** Encryption reduces exposure; it does not make a public repo an appropriate home for a private key. Provision by hand, per machine. |

### The bootstrap ordering problem

1Password templates create a chicken-and-egg: `chezmoi apply` needs `op`, but
`op` arrives via the winget manifest, which *is* the apply. The `op` CLI is also
a separate package from the desktop app and needs CLI integration enabled there
before it will unlock. A rebuild using secret templates is three steps:

```powershell
winget install twpayne.chezmoi AgileBits.1Password AgileBits.1Password.CLI --source winget
op signin
chezmoi init --apply jcouball/sophon-config
```

Worth weighing against keeping secret-bearing files out entirely, which keeps the
bootstrap at two commands.

### If something leaks

**Rotate first, clean up second.** Public repositories are scraped continuously
and automatically; assume any committed credential was harvested within minutes.
`git filter-repo` and a force-push are housekeeping, not remediation, and doing
them first wastes the window in which rotation matters. GitHub also retains
unreachable objects, so the old commit may remain fetchable by SHA afterwards.

---

## Deliberately not managed

- **Secrets and keys.** 1Password holds them; `op` reads them at render time.
- **VS Code extensions.** Settings Sync owns these. Running Sync *and* a managed
  list produces conflicts with no arbiter.
- **Warp's settings** — not by choice. Warp keeps them in
  `%LOCALAPPDATA%\warp\Warp\data\warp.sqlite`, a binary database with no config
  file to version. They will not survive a rebuild and must be redone by hand.
  Windows Terminal's `settings.json` *can* be versioned, which is a quiet
  argument for it as the primary terminal.
- **Windows Terminal's `settings.json`.** Terminal rewrites it whenever its
  generated profiles change, so chezmoi reported permanent drift — and constant
  false drift trains you to ignore the one command that tells you the repo is
  honest. Script 05 patches only `defaultProfile` instead.
- **Anything inside a OneDrive-synced folder.** Two writers, one path, no
  arbiter. Reach those locations through a static stub pointing at an unsynced
  file chezmoi owns.
- **Windows Store apps and inbox components.** Photos, Calculator, media
  extensions, WindowsAppRuntime. Windows owns these.
- **Per-project dependencies.** Gemfiles, package.json, JRuby's own `mvnw`
  wrapper. These belong to their repos.
- **The WSL guest's packages.** Ubuntu 24.04.3 is deliberately bare. If it grows
  past a handful of tools, give it its own chezmoi run against a Linux-scoped
  repo.
- **Brother PowerENGAGE and the Google Gemini PWA.** Accepted exceptions.
- **Anything you'd reinstall in under a minute.** This repo is for what is
  painful to reconstruct, not an inventory.

---

## Small gotchas

- **`core.autocrlf=false`** globally, and `* text=auto eol=lf` here. A Ruby
  checkout is line-ending sensitive, and hook scripts must be LF or `sh` fails
  with a confusing `bad interpreter` error.
- **PowerShell 7 is the MSIX build**, reached through a 0-byte app-execution
  alias at `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`. `$PSHOME` is
  therefore read-only. `winget install Microsoft.PowerShell --scope machine`
  gets the conventional MSI if that ever matters.
- **`$PSVersionTable.PSEdition`** is the thing to branch on — `Desktop` for 5.1,
  `Core` for 7+. Version numbers alone require comparison; the edition is what
  determines behaviour.
