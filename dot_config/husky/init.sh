# Sourced by husky before every git hook.
#
# Git hooks run under Git for Windows' sh.exe, which never sees the PowerShell
# profile. Without this, hooks fired from a GUI client (VS Code's Source Control
# panel, GitButler) have no mise on PATH and fail with "npx: command not found",
# while the identical commit from an activated terminal succeeds.
#
# Prepend mise's shim directory rather than running `eval "$(mise activate bash)"`.
# On Windows, activate emits a Windows-form, semicolon-separated PATH into this
# POSIX shell: every "C:\..." entry becomes a stray "C" plus a fragment, /usr/bin
# is lost, and husky's own `sh -e "$s"` then dies with "command not found"
# (code 127), so no hook runs at all. Shims are also what mise recommends for
# non-interactive contexts like hooks, and they need no shell integration.
#
# The Windows shim path is written as "$HOME/AppData/Local/..." rather than via
# $LOCALAPPDATA on purpose: under MSYS that variable holds a "C:\..." path, and
# prepending it to a colon-separated PATH would reintroduce the same breakage.
#
# Managed by chezmoi (jcouball/sophon-config).

for _mise_shims in \
  "$HOME/AppData/Local/mise/shims" \
  "${XDG_DATA_HOME:-$HOME/.local/share}/mise/shims"
do
  if [ -d "$_mise_shims" ]; then
    PATH="$_mise_shims:$PATH"
    export PATH
    break
  fi
done
unset _mise_shims
