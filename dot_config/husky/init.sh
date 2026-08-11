# Sourced by husky before every git hook.
#
# Git hooks run under Git for Windows' sh.exe, which never sees the PowerShell
# profile. Without this, hooks fired from a GUI client (VS Code's Source Control
# panel, GitButler) have no mise on PATH and fail with "npx: command not found",
# while the identical commit from an activated terminal succeeds.
#
# Managed by chezmoi (jcouball/sophon-config).

if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi
