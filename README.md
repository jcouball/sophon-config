# sophon-config

Configuration for **sophon**, a Windows 11 Pro workstation used mainly for JRuby
development. Managed with [chezmoi](https://chezmoi.io).

Companion to [jcouball/dotfiles](https://github.com/jcouball/dotfiles) (macOS).
This repo is scoped to one machine deliberately: no OS templating, every file is
simply the file.

---

## Rebuild from nothing

Both details are load-bearing and were found the hard way on a clean VM.

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
25H2 VM as a different user. See [Certification](#certification).

---

## The governing rule

> I use Topgrade to manage overall system and core tools, not the dependencies
> for individual software projects. This prevents a global update from
> accidentally breaking a project that depends on specific package versions.
>
> — from the macOS `topgrade.toml`

**System and core tools** can be swept forward in bulk. **Project runtimes** are
pinned, and are never upgraded by a command that also upgrades your browser.
When adding something new, that question decides which layer owns it.

---

## The stack

| Layer | Tool | Owns |
|---|---|---|
| 0 | git + gh | Transport. If it isn't in this repo, it isn't managed. |
| 1 | **chezmoi** | Config file contents, and the manifest of what should be installed. Calls the layers below; installs nothing itself. |
| 2 | **winget** | Applications and stable CLI tools. Driven from `winget-packages.json`. |
| 3 | **mise** | All seven runtimes and build tools — ant, go, java, node, python, ruby, rust. Pinned exactly. |
| 4 | npm · uv · gem · cargo | Libraries and runtime-scoped tools. Subordinate to layer 3. |
| 5 | **topgrade** | Owns nothing. Dispatches layers 2 and 4 plus Windows Update, VS Code and chezmoi. |
| 6 | WSL | POSIX-only tooling. Separate machine, separate management. |

`mise activate pwsh` exports `JAVA_HOME`, `ANT_HOME`, `GOROOT`, `CARGO_HOME` and
`RUSTUP_HOME` — not just `PATH`. That is what lets it own the JDK, which
`mvnw` depends on.

### Ownership rules

| Situation | Owner | Recorded in |
|---|---|---|
| GUI app or stable CLI tool | winget | `winget-packages.json` |
| Language runtime, version matters | mise | `dot_config/mise/config.toml` |
| Library inside a runtime | npm / uv / gem | `.default-npm-packages` etc. |
| Config file contents | chezmoi | the `dot_*` file itself |
| POSIX-only, no native build | WSL | WSL's own setup |

---

## What's in here

```
dot_config/powershell/profile.ps1     mise activation; the real profile
dot_config/husky/init.sh              git hooks get mise on PATH
dot_config/mise/config.toml           the seven pinned runtimes
AppData/Roaming/topgrade.toml         update policy (NOT dot_config - see below)
winget-packages.json                  32 packages; source-only, never deployed
.chezmoi.toml.tmpl                    PowerShell interpreter with -ExecutionPolicy Bypass
.chezmoiscripts/
  run_onchange_01_winget_install      winget import
  run_once_02_powershell_profile_stubs  stubs at $PROFILE, wherever that is
  run_once_03_build_tools             VS Build Tools C++ workload
  run_onchange_after_04_mise_install  materialise the runtimes
  run_once_after_05_terminal_default_profile  point Terminal at pwsh 7
```

**`topgrade.toml` lives at `%APPDATA%`, not `~/.config`.** On macOS it's the Unix
location; on Windows it is not. Put it in the Unix location here and it is
silently inert — `topgrade --dry-run` is what catches that, because excluded
steps still appear.

---

## Everyday tasks

The rule underlying all of them: **the repo must never lag the machine.**

### Install an application

```powershell
winget install <id>
winget export -o (chezmoi source-path)\winget-packages.json
chezmoi cd; git commit -am "Add <id>"; git push
```

Then strip the deliberate exclusions, which `winget export` keeps re-adding —
see the header of `run_onchange_01_winget_install.ps1.tmpl`.

### Uninstall an application

```powershell
winget uninstall --id <id> --exact --purge
winget export -o (chezmoi source-path)\winget-packages.json
```

The manifest has **no cleanup semantics**. Deleting a line never uninstalls
anything; it only stops a rebuild reinstalling it.

### Upgrade a language version

```powershell
mise use -g ruby@4.0.7
chezmoi re-add ~/.config/mise/config.toml
chezmoi cd; git commit -am "ruby 4.0.6 -> 4.0.7"; git push
```

### Change a managed config

```powershell
chezmoi re-add ~/.config/powershell/profile.ps1
# or: chezmoi edit ~/.config/powershell/profile.ps1 --apply
```

### Update everything

```powershell
topgrade --dry-run
topgrade
```

Weekly, elevated, with Warp and Teams closed. A non-elevated bulk upgrade gets
partway and blocks invisibly on a prompt it cannot display.

### Check for drift

```powershell
chezmoi status
chezmoi diff
```

### A tool neither manager has

Do **not** hand-extract to `C:\Tools` — that is how Ant became invisible to every
inventory and was nearly deleted as vestigial. Use a chezmoi external.

---

## Secrets

This repo is **public**. A value committed and deleted next commit is still in
the history, in every clone, and in GitHub's API. Rotation is the only remedy.

| Situation | Mechanism |
|---|---|
| Mostly-public file, one secret field | 1Password at render time — `{{ onepasswordRead "op://..." }}` |
| Whole file is secret | age encryption — `chezmoi add --encrypt` |
| SSH keys, signing keys | **Don't manage it.** Provision by hand, per machine. |

If something leaks: **rotate first, clean history second.** Public repos are
scraped continuously; assume harvest within minutes. `git filter-repo` is
housekeeping, not remediation.

---

## Certification

A clean `chezmoi diff` proves the repo describes this machine. It says nothing
about whether the repo can *produce* one. So the rebuild was run against a
throwaway Hyper-V VM — Windows 11 Enterprise 25H2, build 26200, user `certuser`.

**Eleven defects surfaced. Every one was invisible on sophon**, and all sat in
the recovery path you would only exercise under pressure.

| Defect | Why sophon masked it |
|---|---|
| `winget install` fails without `--source winget` | sophon's `msstore` source is healthy |
| `ExecutionPolicy=Restricted` blocks every script | sophon is `RemoteSigned` |
| Profile stub path hardcoded to OneDrive | sophon's Documents *is* redirected there |
| Scripts ordered before the tools they use | everything already installed |
| No `PATH` refresh for same-run installs | mise and pwsh already on `PATH` |
| `winget import` ignores `InitialOverrideArguments` | Build Tools installed by hand, with workload |
| `winget install` silently no-ops on installed packages | never exercised |
| Build Tools script hit the msstore failure too | as above |
| **Script 04 ran before its own config file existed** | config already on disk |
| Windows Terminal rewrites its `settings.json` | corrosive only over time |
| Warp's installer is very slow and opens a window | tolerable interactively |

Three were caught by *reasoning* about a machine that wasn't sophon — asking what
would happen to a user named `certuser` — before the VM ran. The other eight
needed a real clean machine. Three revert-and-retry cycles to a clean run.

### The one that justifies the exercise

Script 04 ran before chezmoi had written `~/.config/mise/config.toml`, because
`.chezmoiscripts/` sorts before `.config/` — `.ch` precedes `.co`. mise read no
configuration, found nothing to install, and reported **"all tools are
installed"**. Which was true, and meant nothing.

The run finished clean. No error, no warning. A rebuild would have looked
completely successful and left the machine with no Java, no Ruby and no Ant —
discovered whenever JRuby was next built. Every other failure announced itself.
This one reported success. The fix is the `after_` attribute.

### Re-certify when

Any change to the **bootstrap path**: a new or edited provisioning script, a new
package manager, a change to `.chezmoi.toml.tmpl`, or a managed file whose
location depends on the machine. Not needed for adding a package or bumping a
runtime — those exercise proven ground.

```powershell
Restore-VMCheckpoint -VMName sophon-cert -Name 'clean-windows' -Confirm:$false
# then run the documented bootstrap unmodified, with Start-Transcript
```

Verify **outcomes, not exit codes**: `mise ls --current` with nothing `(missing)`,
the C++ workload present, `$env:JAVA_HOME` populated in a new shell, and
`chezmoi status` empty.

---

## Deliberately not managed

- **Secrets and keys.** 1Password holds them.
- **VS Code extensions.** Settings Sync owns these. Running Sync *and* a managed
  list produces conflicts with no arbiter.
- **Warp's settings.** Not by choice — Warp keeps them in a SQLite database with
  no config file to version. They will not survive a rebuild.
- **Windows Terminal's `settings.json`.** Terminal rewrites it whenever its
  generated profiles change, so chezmoi reported permanent drift. Script 05
  patches only `defaultProfile` instead.
- **Anything inside a OneDrive-synced folder.** Two writers, one path, no
  arbiter. Reach those locations through a static stub.
- **Store apps and inbox Windows components.** Windows owns them.
- **Per-project dependencies.** Gemfiles, package.json, JRuby's own `mvnw`.
- **Brother PowerENGAGE and the Google Gemini PWA.** Accepted exceptions.

---

## Notes

- **Shell is PowerShell 7** (`pwsh`). Windows PowerShell 5.1 lacks `&&`/`||`,
  defaults to ANSI encoding, and misreports `$?` for native commands. Activation
  works in 5.1 too; only mise's `chpwd` hook needs 7.
- **`core.autocrlf=false`** globally, and `* text=auto eol=lf` here. A Ruby
  checkout is line-ending sensitive.
- **JRuby builds natively**, from `C:\Users\james\jruby`, against mise's Zulu 21
  via the repo's own `mvnw.cmd`. WSL is not in that path.
