set shell := ["zsh", "-cu"]

label := "com.josephcourtney.svim"
upstream_remote := "upstream"
upstream_url := "https://github.com/FelixKratz/SketchyVim.git"
upstream_branch := "master"

# Show available commands.
default:
    @just --list

# Build svim. libvim is built automatically when needed.
build:
    make

# Rebuild svim itself without rebuilding libvim.
rebuild:
    make clean
    make

# Rebuild libvim and svim from scratch.
rebuild-all:
    make distclean
    make

# Show code-signing identities available on this Mac.
signing-identities:
    security find-identity -v -p codesigning

# Check that the persistent identity used for local installs exists.
signing-check:
    #!/bin/zsh
    set -euo pipefail
    identity="${SVIM_CODESIGN_IDENTITY:-svim-local}"
    if security find-identity -v -p codesigning | grep -F "$identity" >/dev/null 2>&1; then
      echo "code-signing identity available: $identity"
    else
      echo "code-signing identity not found: $identity" >&2
      echo "run: just signing-setup" >&2
      exit 1
    fi

# One-time setup guidance for a stable local code-signing identity.
signing-setup:
    #!/bin/zsh
    set -euo pipefail
    identity="${SVIM_CODESIGN_IDENTITY:-svim-local}"

    if security find-identity -v -p codesigning | grep -F "$identity" >/dev/null 2>&1; then
      echo "code-signing identity already available: $identity"
      exit 0
    fi

    echo "SketchyVim needs one persistent code-signing identity so macOS privacy"
    echo "permissions survive rebuilds. Create it once in Keychain Access:"
    echo
    echo "  Certificate Assistant -> Create a Certificate..."
    echo "  Name:             svim-local"
    echo "  Identity Type:    Self Signed Root"
    echo "  Certificate Type: Code Signing"
    echo "  Let me override defaults: enabled"
    echo "  Accept the remaining defaults."
    echo
    echo "Then run: just signing-check"
    echo
    echo "If you already have an Apple Development or Developer ID code-signing"
    echo "identity, you may instead set SVIM_CODESIGN_IDENTITY to its name or hash."
    echo
    open -a "Keychain Access"

# Install the current build and run it as a user LaunchAgent.
# This also stops the old Homebrew-managed svim service if one exists.
install: build
    @if command -v brew >/dev/null 2>&1; then brew services stop svim >/dev/null 2>&1 || true; fi
    @just _sign-build
    @just _install-files
    @just _restart-service
    @echo "svim installed and running from $HOME/.local/bin/svim"

# Rebuild the current checkout, sign it, install it, and restart the service.
update: rebuild
    @just _sign-build
    @just _install-files
    @just _restart-service
    @echo "svim rebuilt, signed, installed, and restarted"

# Pull the fork, refresh submodules, rebuild everything, sign, install, and restart.
pull-update:
    git pull --ff-only
    git submodule update --init --recursive
    make distclean
    make
    @just _sign-build
    @just _install-files
    @just _restart-service
    @echo "svim updated from git, rebuilt, signed, installed, and restarted"

# Check whether FelixKratz/SketchyVim has commits not yet in this fork.
upstream-check: _ensure-upstream
    #!/bin/zsh
    set -euo pipefail

    git fetch --quiet {{upstream_remote}} {{upstream_branch}}
    ref="{{upstream_remote}}/{{upstream_branch}}"
    new_count=$(git rev-list --count HEAD.."$ref")

    echo "local:    $(git rev-parse --short HEAD)"
    echo "upstream: $(git rev-parse --short "$ref")"

    if (( new_count == 0 )); then
      echo "upstream: up to date"
      exit 0
    fi

    echo "upstream: $new_count new commit(s)"
    echo
    git log --oneline --decorate HEAD.."$ref"

# Rebase this fork's patch stack onto the latest upstream, rebuild, sign, install, and restart.
# Stops on conflicts so they can be resolved explicitly with git rebase --continue.
sync-upstream: _ensure-upstream
    #!/bin/zsh
    set -euo pipefail

    if [[ -n "$(git status --porcelain)" ]]; then
      echo "working tree is not clean; commit or stash changes first" >&2
      exit 1
    fi

    branch=$(git branch --show-current)
    if [[ "$branch" != "master" ]]; then
      echo "sync-upstream must be run from master (currently: ${branch:-detached})" >&2
      exit 1
    fi

    git fetch {{upstream_remote}} {{upstream_branch}}
    ref="{{upstream_remote}}/{{upstream_branch}}"
    new_count=$(git rev-list --count HEAD.."$ref")

    if (( new_count == 0 )); then
      echo "already up to date with $ref"
      exit 0
    fi

    echo "rebasing local patch stack onto $ref"
    git rebase "$ref"
    git submodule update --init --recursive

    make distclean
    make

    just _sign-build
    just _install-files
    just _restart-service

    echo "synced with $ref, rebuilt, signed, installed, and restarted"
    echo "master was rebased; use 'just push-upstream-sync' to update origin"

# Force-push a successfully rebased master to this fork using lease protection.
push-upstream-sync:
    #!/bin/zsh
    set -euo pipefail

    if [[ -n "$(git status --porcelain)" ]]; then
      echo "working tree is not clean" >&2
      exit 1
    fi

    branch=$(git branch --show-current)
    if [[ "$branch" != "master" ]]; then
      echo "push-upstream-sync must be run from master" >&2
      exit 1
    fi

    git push --force-with-lease origin master

# Rebase onto upstream, build/install it, then update this fork on GitHub.
sync-upstream-push: sync-upstream
    just push-upstream-sync

# Start the installed service.
start:
    @just _start-service

# Stop and unload the installed service.
stop:
    #!/bin/zsh
    set -euo pipefail
    service="gui/$(id -u)/{{label}}"
    if launchctl print "$service" >/dev/null 2>&1; then
      launchctl bootout "$service"
      echo "svim stopped"
    else
      echo "svim is not running"
    fi

# Restart the installed service and reload its plist.
restart:
    @just _restart-service

# Show service, process, and installed signing identity.
status:
    #!/bin/zsh
    set -euo pipefail
    service="gui/$(id -u)/{{label}}"
    installed="$HOME/.local/bin/svim"

    if launchctl print "$service" >/dev/null 2>&1; then
      state=$(launchctl print "$service" | awk '/state =/ { print $3; exit }')
      echo "service: loaded (${state:-unknown})"
    else
      echo "service: not loaded"
    fi

    pids=$(pgrep -x svim || true)
    if [[ -n "$pids" ]]; then
      while IFS= read -r pid; do
        ps -p "$pid" -o pid=,command=
      done <<< "$pids"
    else
      echo "process: not running"
    fi

    if [[ -x "$installed" ]]; then
      echo "signature:"
      codesign -dv --verbose=2 "$installed" 2>&1 | grep -E '^(Identifier|Authority)=' || true
    fi

# Temporarily bypass SketchyVim without losing its current Vim state.
suspend:
    pkill -USR1 -x svim

# Resume SketchyVim after `just suspend`.
resume:
    pkill -USR2 -x svim

# Follow stdout and stderr from the LaunchAgent.
logs:
    @mkdir -p "$HOME/Library/Logs"
    @touch "$HOME/Library/Logs/svim.log" "$HOME/Library/Logs/svim.err"
    tail -f "$HOME/Library/Logs/svim.log" "$HOME/Library/Logs/svim.err"

# Stop the service and remove the installed binary and LaunchAgent.
uninstall:
    @just stop
    rm -f "$HOME/.local/bin/svim"
    rm -f "$HOME/Library/LaunchAgents/{{label}}.plist"
    @echo "svim uninstalled; logs were left in $HOME/Library/Logs"

# Remove build outputs only.
clean:
    make clean

# Remove both SketchyVim and libvim build outputs.
distclean:
    make distclean

_ensure-upstream:
    #!/bin/zsh
    set -euo pipefail

    if git remote get-url {{upstream_remote}} >/dev/null 2>&1; then
      git remote set-url {{upstream_remote}} {{upstream_url}}
    else
      git remote add {{upstream_remote}} {{upstream_url}}
    fi

_sign-build:
    #!/bin/zsh
    set -euo pipefail

    identity="${SVIM_CODESIGN_IDENTITY:-svim-local}"
    if ! security find-identity -v -p codesigning | grep -F "$identity" >/dev/null 2>&1; then
      echo "No persistent code-signing identity '$identity' is available." >&2
      echo "Run 'just signing-setup' once, then retry." >&2
      exit 1
    fi

    make sign-local CODESIGN_IDENTITY="$identity" CODESIGN_IDENTIFIER="{{label}}"

_install-files:
    #!/bin/zsh
    set -euo pipefail

    mkdir -p "$HOME/.local/bin"
    mkdir -p "$HOME/Library/LaunchAgents"
    mkdir -p "$HOME/Library/Logs"

    /usr/bin/install -m 0755 bin/svim "$HOME/.local/bin/svim"

    plist="$HOME/Library/LaunchAgents/{{label}}.plist"
    cat > "$plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>{{label}}</string>

      <key>ProgramArguments</key>
      <array>
        <string>$HOME/.local/bin/svim</string>
      </array>

      <key>RunAtLoad</key>
      <true/>

      <!-- Deliberately no KeepAlive. If Accessibility permission is missing,
           svim exits; launchd must not restart it in a prompt loop. -->

      <key>StandardOutPath</key>
      <string>$HOME/Library/Logs/svim.log</string>

      <key>StandardErrorPath</key>
      <string>$HOME/Library/Logs/svim.err</string>
    </dict>
    </plist>
    PLIST

    plutil -lint "$plist" >/dev/null

_start-service:
    #!/bin/zsh
    set -euo pipefail

    domain="gui/$(id -u)"
    service="$domain/{{label}}"
    plist="$HOME/Library/LaunchAgents/{{label}}.plist"

    if [[ ! -x "$HOME/.local/bin/svim" || ! -f "$plist" ]]; then
      echo "svim is not installed; run: just install" >&2
      exit 1
    fi

    if launchctl print "$service" >/dev/null 2>&1; then
      launchctl kickstart "$service"
    else
      launchctl bootstrap "$domain" "$plist"
    fi

    echo "svim started"

_restart-service:
    #!/bin/zsh
    set -euo pipefail

    domain="gui/$(id -u)"
    service="$domain/{{label}}"
    plist="$HOME/Library/LaunchAgents/{{label}}.plist"

    if [[ ! -x "$HOME/.local/bin/svim" || ! -f "$plist" ]]; then
      echo "svim is not installed; run: just install" >&2
      exit 1
    fi

    if launchctl print "$service" >/dev/null 2>&1; then
      launchctl bootout "$service"
    fi

    # Give the previous process a moment to release SketchyVim's lock file.
    for _ in {1..20}; do
      pgrep -x svim >/dev/null 2>&1 || break
      sleep 0.05
    done

    launchctl bootstrap "$domain" "$plist"
    echo "svim restarted"
