# sophon-config

Configuration for **sophon**, a Windows 11 Pro workstation used mainly for JRuby
development. Managed with [chezmoi](https://chezmoi.io).

Companion to [jcouball/neuromancer-config](https://github.com/jcouball/neuromancer-config) (macOS).
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
| Remote access | OpenSSH server, keys only, LAN only |
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
  - [Remote access over SSH](#remote-access-over-ssh)
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

Script 11 can stop the first apply with a warning to restart Windows: the
OpenSSH server capability sometimes needs a restart before its service exists.
Restart, open a new elevated terminal, and run `chezmoi apply`. chezmoi re-runs
script 11, which failed, and anything after it.

This path is **certified** — run end to end on a clean Windows 11 Enterprise
25H2 VM as a different user. See [Certification](#certification) for what that
found.

Afterwards, by hand:

- Open Windows Terminal once, then run `chezmoi apply` again. Terminal
  generates its pwsh profile the first time it opens after pwsh is installed,
  and script 05 cannot set the default profile before that exists. The second
  apply does it; nothing else re-runs.
- Warp if you want it, and Warp's own settings, which cannot be versioned.
- Mark the LAN Private, or the firewall blocks SSH. Script 11 warns when no
  network is. In an elevated terminal, with the LAN adapter's name (`Ethernet`
  on sophon):

  ```powershell
  Get-NetConnectionProfile | Select-Object InterfaceAlias, Name, NetworkCategory
  Set-NetConnectionProfile -InterfaceAlias Ethernet -NetworkCategory Private
  ```

---

## Playbooks

The rule underlying all of them: **the repo must never lag the machine.**
Whenever you install, remove or re-pin something, the corresponding file goes
back into the repo in the same sitting.

### Layer 2 — applications and core tools

#### Install an application

```powershell
winget install <id>
Update-WingetManifest
chezmoi cd; git commit -am "Add <id>"; git push
```

`Update-WingetManifest` is a function in the managed PowerShell profile. It
rewrites `winget-packages.json` from what is actually installed and strips the
deliberate exclusions, which `winget export` keeps re-adding. Currently
excluded: **`Warp.Warp`**, whose installer takes an extraordinarily long time and
opens a welcome window mid-provisioning. Install it by hand when wanted.

#### Uninstall an application

```powershell
winget uninstall --id <id> --exact --purge
Update-WingetManifest
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

Microsoft.Edge is pinned by script 12, because `winget upgrade --all` cannot
upgrade the copy Windows installed and Edge Update keeps it current anyway.
The script's header has the details.

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
# .chezmoiexternal.toml.tmpl
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

### SSH access

#### Authorize a Mac

Done once per Mac, mostly on the Mac.

1. **Choose a passphrase.** Generate one in 1Password and save it there. The
   Keychain copy from step 3 is lost with the Keychain, so 1Password is the
   copy that survives a new Mac. The 1Password CLI (`op`) does it, saving to
   your default vault. It creates the item only if none exists, because
   1Password allows duplicate titles and `op item get` refuses a title that
   matches two items. Re-running this reuses the passphrase the key already
   has.

   ```sh
   op item get "sophon SSH key passphrase" > /dev/null 2>&1 ||
     op item create --category password --title "sophon SSH key passphrase" \
       --generate-password='letters,digits,symbols,32' > /dev/null
   ```

   Check: this prints `1`. Anything higher means duplicate items; delete the
   extras in 1Password before step 2.

   ```sh
   op item list --categories Password | grep -c 'sophon SSH key passphrase'
   ```

   Steps 2 and 3 read the passphrase from 1Password, so it is never typed,
   pasted or written to disk. Copying it through the clipboard fails: copying
   the next command from this README replaces it.

2. **Generate a key for sophon alone.** The passphrase is what makes a copied
   key file useless, so never generate this key without one. `-N` puts the
   passphrase in the process list while `ssh-keygen` runs, about a second,
   which on a single-user Mac is acceptable. The comment names this Mac's
   account and hostname, so each Mac's line in `administrators_authorized_keys`
   says whose it is when you need to revoke it.

   The `[ -n "$pass" ]` guard matters: if `op` fails, for example because the
   unlock prompt was dismissed, `-N ""` would create a key with no passphrase
   and print nothing different.

   ```sh
   pass=$(op item get "sophon SSH key passphrase" --fields label=password --reveal) &&
     [ -n "$pass" ] &&
     ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_sophon \
       -C "$USER@$(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]') to sophon" \
       -N "$pass"
   unset pass
   ```

   Check: this fails with `incorrect passphrase supplied to decrypt private
   key`. If it prints a public key instead, the key has no passphrase; delete
   both files and generate it again.

   ```sh
   ssh-keygen -y -P '' -f ~/.ssh/id_ed25519_sophon
   ```

   Check: this prints `match`, proving the 1Password passphrase opens the key.

   ```sh
   [ "$(ssh-keygen -y -f ~/.ssh/id_ed25519_sophon \
          -P "$(op item get "sophon SSH key passphrase" --fields label=password --reveal)" |
        cut -d' ' -f1-2)" = "$(cut -d' ' -f1-2 ~/.ssh/id_ed25519_sophon.pub)" ] && echo match
   ```

3. **Store the passphrase in the Keychain**, so scripts and other
   non-interactive callers never meet a prompt. `ssh-add` gets the passphrase
   from a throwaway askpass script that asks `op` for it; the script holds the
   `op` command, not the passphrase.

   ```sh
   askpass=$(mktemp) && chmod 700 "$askpass" &&
     printf '#!/bin/sh\nexec op item get "sophon SSH key passphrase" --fields label=password --reveal\n' > "$askpass" &&
     SSH_ASKPASS="$askpass" SSH_ASKPASS_REQUIRE=force \
       ssh-add --apple-use-keychain ~/.ssh/id_ed25519_sophon
   rm -f "$askpass"
   ```

   Check: this prints the key's `to sophon` line. It removes the key from the
   agent and loads it back from the Keychain, so it proves the Keychain holds
   the passphrase, which is what survives a reboot. `ssh-add -l` alone shows
   only what the agent holds now. Your other keys stay loaded.

   ```sh
   ssh-add -d ~/.ssh/id_ed25519_sophon &&
     ssh-add --apple-load-keychain &&
     ssh-add -l | grep 'to sophon'
   ```

4. **Give the Mac a host entry.** It belongs in the client's own config repo,
   not here. On Neuromancer, follow neuromancer-config's
   [Change a managed config](https://github.com/jcouball/neuromancer-config#change-a-managed-config)
   playbook for `~/.ssh/config`.

   First find sophon's address. On sophon, this prints the address of the
   adapter with the default route:

   ```powershell
   (Get-NetIPConfiguration | Where-Object IPv4DefaultGateway).IPv4Address.IPAddress
   ```

   sophon gets that address from DHCP, so reserve it for sophon in the router.
   Without a reservation the lease can move it, and this entry stops working.

   The entry, with that address in place of the placeholder:

   ```text
   Host sophon
     HostName <sophon's address>
     User james
     IdentityFile ~/.ssh/id_ed25519_sophon
     IdentitiesOnly yes
     StrictHostKeyChecking accept-new
     ForwardAgent no
     WarnWeakCrypto no-pq-kex
     UseKeychain yes
     AddKeysToAgent yes
     ControlMaster auto
     ControlPath ~/.ssh/cm-%r@%h:%p
     ControlPersist 10m
   ```

   `UseKeychain` is what lets `ssh` read the passphrase back from the Keychain
   after a reboot; without it, anything non-interactive stops at a prompt it
   cannot answer. `ControlMaster` keeps one connection open for ten minutes,
   so a caller issuing dozens of short commands pays for the handshake once.
   `accept-new` records sophon's host key on the first connection and refuses
   one that changes later. After a rebuild of sophon, delete its old line with
   `ssh-keygen -R <sophon's address>`. `WarnWeakCrypto no-pq-kex` is for
   OpenSSH 10 clients, which warn on every connection that does not use a
   post-quantum key exchange. sophon's OpenSSH for Windows 9.5 offers none,
   and no server setting adds one. The risk, LAN traffic recorded now and
   decrypted later, is accepted; the option turns off only that warning.

   ssh takes the first value it finds for each setting, so this entry must
   come before any settings meant for every host. Settings at the top of the
   file outside a `Host` block apply to every host and win over this entry;
   move them into a `Host *` block at the end of the file. Left in place, a
   global `ForwardAgent yes` and `StrictHostKeyChecking no` would let another
   machine on the LAN pose as sophon without a warning and receive the
   forwarded agent, with every key in it. neuromancer-config's file is already
   in this order.

   Check: this prints sophon's address, `james`, the sophon key,
   `stricthostkeychecking accept-new` and `forwardagent no`. `ssh -G` prints
   the settings a connection would use without connecting, so it works before
   sophon is set up.

   ```sh
   ssh -G sophon | grep -E '^(hostname|user|identityfile|stricthostkeychecking|forwardagent) '
   ```

5. **Add the public key line**, from a clone of the sophon-config repo on the Mac,
   where the `.pub` file is. The `restrict,pty` prefix is required; the header of
   `administrators_authorized_keys` says what each option does.

   Commit only the key file, on a branch, and merge it through a pull request.

   ```sh
   cd ~/github/jcouball/sophon-config
   host=$(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]')
   git switch -c "authorize-$host"
   printf 'restrict,pty %s\n' "$(cat ~/.ssh/id_ed25519_sophon.pub)" >> administrators_authorized_keys
   git commit administrators_authorized_keys -m "Authorize $host's SSH key"
   git push -u origin HEAD
   gh pr create --fill
   ```

6. **Apply on sophon**, after the pull request is merged, from an **elevated** terminal. The key file's hash is
   in script 11, so a changed key re-runs it.

   ```powershell
   chezmoi update
   ```

7. **Check from the Mac.** All three should answer. An empty `JAVA_HOME`
   means the session ran without the profile; see
   [Small gotchas](#small-gotchas).

   ```sh
   ssh sophon '$PSVersionTable.PSVersion.ToString(); $env:JAVA_HOME; ruby -v'
   ```

#### Revoke a key

Delete its line from `administrators_authorized_keys`, merge, and run an
elevated `chezmoi update`. Script 11 rewrites the server's copy, so sophon
refuses new logins with that key. It does not end connections already open,
including a client's `ControlPersist` connection, which lasts ten minutes
after its last use. To cut those off too, end the connection processes from
an elevated terminal. Each connection has its own `sshd.exe`, and restarting
the service does not touch them, so the service's own process is left alone
and the rest are stopped. This drops every SSH session, not just the revoked
client's:

```powershell
$service = (Get-CimInstance Win32_Service -Filter "Name='sshd'").ProcessId
Get-Process sshd, sshd-session -ErrorAction SilentlyContinue |
    Where-Object Id -ne $service | Stop-Process -Force
```

The key keeps working until an elevated apply succeeds: an unelevated run,
such as topgrade's, cannot write under `C:\ProgramData`, and script 11 stops
at its elevation check. Removing the last key leaves nobody able to log in, and
script 11 warns to say so.

#### Change sshd's config

Edit `sshd_config` in the repo, merge, and run an elevated `chezmoi update`.
Script 11 checks the repo's file before touching the server's, with `sshd -t`
for syntax and `sshd -T` for passwords off and keys from the managed file,
copies it into place when the server's copy differs, and restarts sshd so the
new file is the one new connections get. Open sessions, including one running
the apply, are not ended by the restart: each has its own `sshd.exe`, which
keeps the config and shell it started with until it closes. A file that fails a check never reaches the
server, which keeps running the file it was last locked with, the one
`sshd_config.applied` records. An edit made directly in
`C:\ProgramData\ssh\sshd_config` lasts until the next elevated apply.

#### Bump sshd's pwsh

When the weekly topgrade run warns that sshd's pwsh is behind the interactive
one, under its `sshd pwsh drift` step, it prints the new `version` and a `gh`
command that returns the matching `sha256`. Both go in `.chezmoidata.toml`.

Each version unpacks into its own folder, `~/.local/opt/pwsh-<version>`, so a
bump never overwrites a pwsh an SSH session is running, and open sessions can
stay open. Script 11 switches sshd to the new folder once that pwsh starts, so
the apply that does the bump must be **elevated**. An unelevated apply, such as
topgrade's, unpacks the new folder but fails at script 11, and sshd keeps the
old version until an elevated apply runs.

Start a branch in the source directory, edit the two values, and apply. The git
commands go through `chezmoi git`: `chezmoi cd` starts a new shell, so commands
chained after it never run there.

```powershell
chezmoi git -- switch -c bump-sshd-pwsh
code --wait "$(chezmoi source-path)\.chezmoidata.toml"
chezmoi apply
```

Check: this prints that sshd's pwsh matches the interactive one, which also
proves the new version runs and that sshd now starts it.

```powershell
& "$HOME\.local\bin\sshd-pwsh-drift.ps1"
```

Script 11 keeps the old folder through this apply and deletes it the next
time it runs, with the next key change or bump. A connection a client keeps
open between commands, which the `ControlPersist` setting in the
[client config](#authorize-a-mac) does for ten minutes, starts the shell its
sshd process read at login, even after `DefaultShell` changes, so deleting
the folder at once would break that connection's next command. Folders older
than that are deleted in the same apply unless a session is still running one.

Commit only the pin, and merge it through a pull request:

```powershell
chezmoi git -- commit .chezmoidata.toml -m "sshd pwsh 7.6.7 -> 7.6.8"
chezmoi git -- push -u origin HEAD
gh pr create --repo jcouball/sophon-config --head bump-sshd-pwsh `
  --title "sshd pwsh 7.6.7 -> 7.6.8" --body "Bump the pwsh ZIP that sshd runs."
```

After it merges, put the source directory back on `main`, or later
`chezmoi update` runs stay on the branch:

```powershell
chezmoi git -- switch main
chezmoi git -- pull
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
cmd /c "cat --version"     # resolves - spawned Unix tools work outside Git Bash (script 08)
[Environment]::GetEnvironmentVariables('User').Keys -like 'MISE_*_VERSION'   # empty (script 09)
(Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run').Warp[0]   # odd = vetoed (script 10)
Get-Service sshd | Select-Object Status, StartType        # Running, Automatic (script 11)
(Get-ItemProperty HKLM:\SOFTWARE\OpenSSH).DefaultShell    # ...\.local\opt\pwsh-7.6.7\pwsh.exe
sshd -T | Select-String '^(passwordauthentication|authenticationmethods) '   # no; publickey
chezmoi status             # empty
```

Two of those deserve a word. Script 09 is a designed no-op on a clean VM — its
check confirms nothing crept in, not that anything was deleted. Script 10's
check is the interesting one here: it proves the Warp veto is **pre-seeded
before Warp is ever installed**, which is the scenario the script exists for
and the one an already-configured machine cannot test.

The SSH checks stop at the server's configuration. A login needs an authorized
private key, and none lives on the VM, so try one from an authorized machine
against sophon after the next real apply.

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
.chezmoidata.toml                     sshd's pwsh version and checksum
.chezmoiexternal.toml.tmpl            sshd's pwsh, a pinned ZIP, one folder per version
.gitattributes                        * text=auto eol=lf
winget-packages.json                  33 packages; read by script 01, never deployed
administrators_authorized_keys        public keys for SSH; read by script 11, never deployed
sshd_config                           sshd's config; copied to C:\ProgramData\ssh by script 11

dot_config/powershell/profile.ps1     mise activation; the real profile
dot_config/husky/init.sh              git hooks get mise on PATH
dot_config/mise/config.toml           the seven pinned runtimes
AppData/Roaming/topgrade.toml         update policy - NOT dot_config, see below
dot_local/bin/sshd-pwsh-drift.ps1.tmpl   weekly, from topgrade: warn when sshd's pwsh lags

.chezmoiscripts/
  run_onchange_01_winget_install.ps1.tmpl          winget import
  run_once_02_powershell_execution_policy.ps1      let 5.1 load the stubs at all
  run_once_02_powershell_profile_stubs.ps1         stubs at $PROFILE, wherever that is
  run_once_03_build_tools.ps1                      VS Build Tools C++ workload
  run_onchange_after_04_mise_install.ps1.tmpl      materialise the runtimes
  run_onchange_after_05_terminal_default_profile.ps1.tmpl   point Terminal at pwsh 7
  run_onchange_after_06_ruby_devkit.ps1.tmpl       MSYS2 toolchain for native gems
  run_once_after_07_mise_shims_path.ps1            shims on user PATH, for cmd.exe
  run_once_after_08_git_unix_tools_path.ps1        Git's usr\bin on user PATH, for spawned Unix tools
  run_once_after_09_remove_stale_mise_version_pins.ps1   delete persisted MISE_*_VERSION env vars
  run_once_after_10_disable_warp_autostart.ps1     veto Warp's run-at-sign-in registration
  run_onchange_after_11_openssh_server.ps1.tmpl    SSH server: keys only, LAN only, ZIP pwsh
  run_once_after_12_winget_pin_edge.ps1            keep winget upgrade --all off Edge
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
script 05 points its `defaultProfile` at pwsh 7. On a rebuild this lands one
apply late: Terminal generates its pwsh profile only when opened after pwsh is
installed, so the first apply skips the step, and the script is `run_onchange`
on `settings.json` so the next apply after Terminal has been opened finishes it.

**Warp is a personal preference, installed by hand.** It is deliberately
excluded from the manifest (its installer is extremely slow and opens a welcome
window mid-provisioning), so a rebuild will not have it. Install it whenever you
want it, and set its default shell to pwsh in its own settings:

```powershell
winget install Warp.Warp --source winget
```

Warp's shell preference cannot be scripted — see
[Deliberately not managed](#deliberately-not-managed).

Warp's installer also registers it to launch at every sign-in. Script 10 vetoes
that the way Task Manager's "Disable" does — a `StartupApproved` flag Explorer
honours over the Run entry itself — so the veto survives Warp updates, and is
pre-seeded on a rebuild so a later hand-install stays quiet. Launching Warp by
hand is unaffected.

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

Script 08 uses the same channel to append Git for Windows' `usr\bin`, so
spawned Unix tools (`cat`, `false`, `sleep` — process_executer's spec suite
lives on these) resolve outside Git Bash too. The persisted user PATH is the
*only* channel that reaches a `-NoProfile` shell — and Claude Code in VS Code
runs every command in one, so neither activation nor the profile can help it.

| Shell | Tools via | Why |
| --- | --- | --- |
| pwsh 7 | activation, plus shims | Profile loads; policy is `RemoteSigned` from a `powershell.config.json` inside its install directory |
| Windows PowerShell 5.1 | activation, plus shims | Only since script 02 set `CurrentUser` to `RemoteSigned`. Before that the stub was refused and the shell had nothing |
| cmd.exe | shims only | mise has **no** cmd.exe activation. There is no hook to install. Shims are the only route |
| pwsh 7 over SSH | activation, plus shims | sshd starts the ZIP copy at `~/.local/opt/pwsh-<version>`, which reads the same `$PROFILE` stub as the MSIX build |
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

## Remote access over SSH

This machine runs Windows' OpenSSH server, so another machine on the LAN can
run commands here. Each session logs in as james, starts pwsh 7 with the managed
profile, and so sees the same mise runtimes, `JAVA_HOME` and checkouts as a
terminal on the desk. Script 11 sets this up. The
[playbooks](#ssh-access) cover adding a key, revoking one, and bumping pwsh.

### Windows' own server, set up by a script

The OpenSSH server is a Windows optional capability, not a winget package, so
the manifest cannot install it and script 11 does. The same script owns the
three settings outside the home directory that make it usable:
`C:\ProgramData\ssh\sshd_config`, the authorized keys beside it, and the
`DefaultShell` value under `HKLM:\SOFTWARE\OpenSSH`.

`sshd_config` is copied from the repo's `sshd_config`, not checked. An
earlier version edited one directive in Windows' default file and scanned the
rest for anything that could let a client in another way. That scan had to
parse the file the way sshd does and know every authentication method sshd
has, and each review found another spelling or method it missed. A copied
file needs neither. The repo's copy states only the authentication settings
and what differs from sshd's defaults, so everything else follows the sshd
Windows ships. An edit on sophon is overwritten by the next elevated apply;
the [playbook](#change-sshds-config) says where to make one.

Two more files sit beside `sshd_config` on sophon. `sshd_config.applied` is
the config the server was last locked with: script 11 writes it at the point
it opens the firewall, so at rest it is identical to `sshd_config` and to the
repo's copy. It matters only during an apply that changes the config. The
server is still running the previous file then, and `.applied` is how script
11 knows that file is trusted, so a rejected replacement leaves the server
as it was instead of stopping it. `sshd_config.bak` is the previous file too,
but a scratch copy, written just before a replacement so a file that `sshd -t`
rejects in place can be put back. Nothing reads it afterwards.

### An admin login, and what limits it

Sessions log in as james so they share the runtimes and checkouts. A
dedicated non-admin account would need its own mise installs and its own
`chezmoi apply`, and scripts 01 and 03 assume an elevated run. The cost is
real: james is an administrator, and Windows does not filter an
administrator's token for a key login, so **every SSH session has full admin
rights.** Four limits narrow who can get one:

| Limit | Where |
| --- | --- |
| Keys only, from one file. `AuthenticationMethods publickey` allows nothing else, and the repo's `sshd_config` is the one sshd runs. Script 11 confirms both with `sshd -T` | `sshd_config`, script 11 |
| Port 22 answers only on Private networks, from the local subnet | firewall rule `OpenSSH-Server-In-TCP`, script 11 |
| No port, agent, X11 or tunnel forwarding. `DisableForwarding yes`, which no key option can override, and `restrict` on every key line as a second check | `sshd_config`, `administrators_authorized_keys` |
| Each private key has a passphrase, so a copied key file is useless. sophon cannot enforce this | each client; on a Mac, the Keychain holds it |

The limits stop at who can log in. A session runs pwsh from
`~/.local/opt/pwsh-<version>` and loads `$PROFILE` and mise from the home directory, and
james can change all of that without elevation. So anything that can write to
james's home gets admin rights at the next SSH login. That is accepted, not
fixed. Windows does not treat UAC as a security boundary, so a process running
as james, an administrator, already has other ways to elevate. Moving pwsh out
of the home directory would close one of these paths and leave the profile and
mise open.

Locking each key to its client's address with `from=` was considered and
dropped. The firewall already confines logins to the LAN, so `from=` only adds
protection against a stolen key used from another device on it, and the
passphrase covers that case without locking a client out whenever its address
changes.

### A second pwsh, just for sshd

sshd is a Windows service, and a service cannot start the MSIX build of pwsh
that the manifest installs. Microsoft documents MSIX as unsupported for
remoting and for execution by system services, and its real `pwsh.exe` sits
under a versioned `WindowsApps` path that changes on every update. The MSI
build has neither problem, but Microsoft ships no MSI from PowerShell 7.7 on,
so choosing it would only defer the question.

The ZIP build is the same binaries with no installer.
`.chezmoiexternal.toml.tmpl` pins it, checks its sha256, and unpacks it to
`~/.local/opt/pwsh-<version>`, a path with no spaces. The version and checksum
live in `.chezmoidata.toml`. It is not on `PATH`, so interactive shells still
get the MSIX build. Both read the same `$PROFILE`, so a session gets the same
environment either way.

Each version gets its own folder because every SSH session runs this pwsh,
and a running pwsh holds its files locked. Replacing them in place could stop
partway and leave every login broken. A bump instead unpacks the new version
beside the old one. Script 11 switches sshd's `DefaultShell` once the new pwsh
starts, and deletes old folders no session is using.

The cost is a second copy that only updates when the pin changes. topgrade
runs `~/.local/bin/sshd-pwsh-drift.ps1` weekly, after its chezmoi step, so
drift surfaces within a week as a warning that prints the bump. It is a
topgrade command, not a chezmoi script, because a script that runs on every
apply is always pending, and `chezmoi status` would never come back empty.
Following the MSIX version automatically was rejected. It needs the MSIX
version when chezmoi renders its templates, which on a rebuild is before
script 01 has installed MSIX. It also changes the binary behind every admin
login without a commit to record it.

### What a session cannot do

- **Anything needing the desktop.** sshd sessions are non-interactive, so a
  GUI app cannot show a window you could see. Use the KVM, or sit at the
  machine.
- **Use stored credentials.** Expect `gh` and Git Credential Manager to fail
  inside a session; [Small gotchas](#small-gotchas) has the reason and the
  workaround.

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

The guest account is `certuser`, a local account. Its password is in
1Password, under `sophon-config certification VM`, with the security-question
answers and the setup choices. The first VM was lost because
nothing recorded where the password was: its `clean-windows` checkpoint had
been taken at the sign-in screen, so a restore landed on a lock screen nobody
could open, and the VM had to be rebuilt from the ISO. Take the checkpoint
while logged in.

The image is Enterprise Evaluation, which runs for 90 days from install and
then warns, and later shuts the VM down every hour. A restore does not reset
that clock, since it restores the install date with everything else. When
the warning appears, `slmgr /rearm` from an elevated terminal inside the VM
starts another 90 days (Enterprise Evaluation allows this a few times);
restart, then take a fresh `clean-windows` checkpoint so later restores
inherit the extension. The same refresh, restore, let Windows Update finish,
restart, re-checkpoint, is worth doing before any certification run months
after the last one, so updates do not reboot the VM mid-apply.

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
| SSH public keys | Commit as-is. `administrators_authorized_keys` holds the clients' public keys, which are not secrets. |

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
- **The client side of SSH.** Private keys and `Host sophon` entries live on
  each client. The Mac's are in jcouball/neuromancer-config.
- **The network category.** Marking a network Private says it is trusted,
  which is a judgment about that network, and Windows' profile names
  ("Network 3") do not identify the LAN reliably. Script 11 also runs on the
  certification VM, whose NAT network should stay Public. So it only warns,
  and the rebuild lists marking the LAN Private as a step by hand.
- **GitHub credentials for SSH sessions.** If a session needs them, they are a
  by-hand, per-machine secret like any other; see [Small gotchas](#small-gotchas).
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
- **`MISE_*_VERSION` environment variables outrank `config.toml`.** mise treats
  them as its highest-precedence pin, so one persisted in the user environment
  overrides layer 3 machine-wide — and Explorer hands the value to everything it
  launches until the next sign-in, even after the registry entry is gone. It
  presents as the wrong runtime version with nothing saying why; `mise ls
  <tool>` names the winning source. Script 09 deletes any it finds. Never
  `setx` one.
- **`Restart-Service sshd` does not end open SSH sessions.** Each connection
  runs in its own `sshd.exe`, a child of the service that outlives it. A
  restart changes what new connections get; a session open across it keeps
  the old config and the old `DefaultShell`. To end sessions, stop those
  processes, as the [revoke playbook](#revoke-a-key) does. Three reviewers
  and one author assumed otherwise before the apply was run.
- **`sshd -t` and `sshd -T` hang on a rejected config when stderr is a pipe.**
  OpenSSH for Windows 9.5 never returns from either when it has an error to
  report and stderr is not a console, which it is not under chezmoi or over
  SSH. Only `-E <logfile>`, or a redirect to a file, returns. Script 11 runs
  every sshd check with `-E` for that reason; a check added without it works
  until the first bad config, then stops the apply for good.
- **Inside an SSH session, `pwsh` on `PATH` is still the MSIX alias**, which a
  session may not be able to start. Use `& "$PSHOME\pwsh.exe"` for a child
  shell; `$PSHOME` is the ZIP copy that sshd launched.
- **Credential Manager is likely locked in an SSH session.** A key login hands
  Windows no password, and the password is what unlocks DPAPI, which protects
  Credential Manager. Expect `gh` and Git Credential Manager to fail with "A
  specified logon session does not exist". Check with
  `ssh sophon 'gh auth status'`. Public repos clone without credentials; for
  private ones, the simplest route is to send the code from the client. Storing a
  token in plain text on sophon is the other route, and it is a by-hand
  secret, never this repo.
- **An SSH session runs without mise if the profile stub cannot be read.** The
  stub lives in the OneDrive-redirected Documents folder. If OneDrive has made
  it online-only and is not running, the session starts with no activation and
  an empty `JAVA_HOME`. Mark `Documents\PowerShell` "Always keep on this
  device".
- **A tool installed while sshd is running can be missing over SSH.** If it
  works in a new local terminal but not in a session, run
  `Restart-Service sshd` elevated.
