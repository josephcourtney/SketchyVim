set shell := ["zsh", "-cu"]

label := "com.josephcourtney.svim"
watch_label := "com.josephcourtney.svim-upstream-check"
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

# Report whether the installed svim currently has Accessibility access.
access-check:
    #!/bin/zsh
    set -euo pipefail
    svim="$HOME/.local/bin/svim"
    if [[ ! -x "$svim" ]]; then
      echo "svim is not installed; run: just install" >&2
      exit 1
    fi
    if "$svim" --check-access; then
      echo "Accessibility access: granted"
    else
      echo "Accessibility access: not granted"
      exit 1
    fi

# Explicitly request Accessibility access once. The service is stopped first.
access-request:
    #!/bin/zsh
    set -euo pipefail
    just stop
    svim="$HOME/.local/bin/svim"
    if [[ ! -x "$svim" ]]; then
      echo "svim is not installed; run: just install" >&2
      exit 1
    fi
    "$svim" --request-access
    echo
    echo "After granting access in System Settings, run: just start"

# Install the current build and run it as a user LaunchAgent when authorized.
# Also install the periodic upstream update watcher.
# This also stops the old Homebrew-managed svim service if one exists.
install: build
    @if command -v brew >/dev/null 2>&1; then brew services stop svim >/dev/null 2>&1 || true; fi
    @just _sign-build
    @just _install-files
    @just _install-upstream-watch
    @just _restart-if-authorized
    @just _restart-upstream-watch
    @echo "svim installed at $HOME/.local/bin/svim"

# Rebuild the current checkout, sign it, install it, and restart when authorized.
update: rebuild
    @just _sign-build
    @just _install-files
    @just _install-upstream-watch
    @just _restart-if-authorized
    @just _restart-upstream-watch
    @echo "svim rebuilt, signed, and installed"

# Pull the fork, refresh submodules, rebuild everything, sign, install, and restart.
pull-update:
    git pull --ff-only
    git submodule update --init --recursive
    make distclean
    make
    @just _sign-build
    @just _install-files
    @just _install-upstream-watch
    @just _restart-if-authorized
    @just _restart-upstream-watch
    @echo "svim updated from git, rebuilt, signed, and installed"

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

# Run the same one-shot upstream check used by the scheduled watcher.
# Sends at most one notification per upstream commit and emits the
# `svim_upstream_update` SketchyBar event when SketchyBar is available.
upstream-watch:
    @SVIM_REPO_PATH="$(git rev-parse --show-toplevel)" /bin/zsh scripts/upstream-watch.sh

# Install/reinstall and immediately run the six-hour upstream watcher.
upstream-watch-install:
    @just _install-upstream-watch
    @just _restart-upstream-watch

# Stop the scheduled upstream watcher without affecting svim itself.
upstream-watch-stop:
    #!/bin/zsh
    set -euo pipefail
    service="gui/$(id -u)/{{watch_label}}"
    if launchctl print "$service" >/dev/null 2>&1; then
      launchctl bootout "$service" || true
    fi
    echo "svim upstream watcher stopped"

# Show whether the periodic upstream watcher is loaded.
upstream-watch-status:
    #!/bin/zsh
    set -euo pipefail
    service="gui/$(id -u)/{{watch_label}}"
    state_file="${XDG_STATE_HOME:-$HOME/.local/state}/svim/upstream-notified"

    if launchctl print "$service" >/dev/null 2>&1; then
      state=$(launchctl print "$service" | awk '/state =/ { print $3; exit }')
      echo "watcher: loaded (${state:-waiting})"
    else
      echo "watcher: not loaded"
    fi

    echo "interval: 6 hours"
    if [[ -f "$state_file" ]]; then
      echo "last notified upstream: $(cut -c1-12 "$state_file")"
    else
      echo "last notified upstream: none"
    fi

# Rebase this fork's patch stack onto the latest upstream when needed, then always
# rebuild, sign, install, and restart the current master.
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

    if (( new_count > 0 )); then
      echo "rebasing local patch stack onto $ref"
      git rebase "$ref"
    else
      echo "already up to date with $ref; rebuilding and installing current master"
    fi

    git submodule update --init --recursive

    make distclean
    make

    just _sign-build
    just _install-files
    just _install-upstream-watch
    just _restart-if-authorized
    just _restart-upstream-watch

    if (( new_count > 0 )); then
      echo "synced with $ref, rebuilt, signed, and installed"
      echo "master was rebased; use 'just push-upstream-sync' to update origin"
    else
      echo "upstream already current; rebuilt, signed, installed, and restarted current master"
    fi

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

# Rebase onto upstream if needed, always build/install/restart, then update the fork.
sync-upstream-push: sync-upstream
    just push-upstream-sync

# Start the installed service. Does not prompt for Accessibility permission.
start:
    @just _start-service

# Stop all known svim services and processes, including the legacy Homebrew service.
stop:
    #!/bin/zsh
    set -euo pipefail
    service="gui/$(id -u)/{{label}}"

    if launchctl print "$service" >/dev/null 2>&1; then
      launchctl bootout "$service" || true
    fi

    if command -v brew >/dev/null 2>&1; then
      brew services stop svim >/dev/null 2>&1 || true
    fi

    pkill -x svim >/dev/null 2>&1 || true
    echo "svim stopped"

# Restart the installed service. Does not prompt for Accessibility permission.
restart:
    @just _restart-service

# Show service, process, access, signing identity, and watcher state.
status:
    #!/bin/zsh
    set -euo pipefail
    service="gui/$(id -u)/{{label}}"
    watch_service="gui/$(id -u)/{{watch_label}}"
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
      if "$installed" --check-access; then
        echo "Accessibility access: granted"
      else
        echo "Accessibility access: not granted"
      fi
      echo "signature:"
      codesign -dv --verbose=2 "$installed" 2>&1 | grep -E '^(Identifier|Authority)=' || true
    fi

    if launchctl print "$watch_service" >/dev/null 2>&1; then
      echo "upstream watcher: loaded (every 6 hours)"
    else
      echo "upstream watcher: not loaded"
    fi

# Temporarily bypass SketchyVim without losing its current Vim state.
suspend:
    pkill -USR1 -x svim

# Resume SketchyVim after `just suspend`.
resume:
    pkill -USR2 -x svim

# Follow stdout and stderr from the SketchyVim LaunchAgent.
logs:
    @mkdir -p "$HOME/Library/Logs"
    @touch "$HOME/Library/Logs/svim.log" "$HOME/Library/Logs/svim.err"
    tail -f "$HOME/Library/Logs/svim.log" "$HOME/Library/Logs/svim.err"

# Follow stdout and stderr from the periodic upstream watcher.
upstream-watch-logs:
    @mkdir -p "$HOME/Library/Logs"
    @touch "$HOME/Library/Logs/svim-upstream-check.log" "$HOME/Library/Logs/svim-upstream-check.err"
    tail -f "$HOME/Library/Logs/svim-upstream-check.log" "$HOME/Library/Logs/svim-upstream-check.err"

# Stop services and remove the installed binary, watcher, and LaunchAgents.
uninstall:
    @just stop
    @just upstream-watch-stop
    rm -f "$HOME/.local/bin/svim"
    rm -f "$HOME/.local/bin/svim-upstream-watch"
    rm -f "$HOME/Library/LaunchAgents/{{label}}.plist"
    rm -f "$HOME/Library/LaunchAgents/{{watch_label}}.plist"
    rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/svim/upstream-notified"
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
    service_path="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
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

      <key>EnvironmentVariables</key>
      <dict>
        <key>PATH</key>
        <string>$service_path</string>
      </dict>

      <key>ProcessType</key>
      <string>Interactive</string>

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

_install-upstream-watch:
    #!/bin/zsh
    set -euo pipefail

    repo=$(git rev-parse --show-toplevel)
    mkdir -p "$HOME/.local/bin"
    mkdir -p "$HOME/Library/LaunchAgents"
    mkdir -p "$HOME/Library/Logs"
    mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/svim"

    /usr/bin/install -m 0755 scripts/upstream-watch.sh "$HOME/.local/bin/svim-upstream-watch"

    plist="$HOME/Library/LaunchAgents/{{watch_label}}.plist"
    service_path="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"
    cat > "$plist" <<PLIST
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>{{watch_label}}</string>

      <key>ProgramArguments</key>
      <array>
        <string>$HOME/.local/bin/svim-upstream-watch</string>
      </array>

      <key>EnvironmentVariables</key>
      <dict>
        <key>PATH</key>
        <string>$service_path</string>
        <key>SVIM_REPO_PATH</key>
        <string>$repo</string>
        <key>SVIM_UPSTREAM_REMOTE</key>
        <string>{{upstream_remote}}</string>
        <key>SVIM_UPSTREAM_URL</key>
        <string>{{upstream_url}}</string>
        <key>SVIM_UPSTREAM_BRANCH</key>
        <string>{{upstream_branch}}</string>
      </dict>

      <key>RunAtLoad</key>
      <true/>

      <key>StartInterval</key>
      <integer>21600</integer>

      <key>StandardOutPath</key>
      <string>$HOME/Library/Logs/svim-upstream-check.log</string>

      <key>StandardErrorPath</key>
      <string>$HOME/Library/Logs/svim-upstream-check.err</string>
    </dict>
    </plist>
    PLIST

    plutil -lint "$plist" >/dev/null

_restart-if-authorized:
    #!/bin/zsh
    set -euo pipefail
    svim="$HOME/.local/bin/svim"
    if "$svim" --check-access; then
      just _restart-service
    else
      service="gui/$(id -u)/{{label}}"
      launchctl bootout "$service" >/dev/null 2>&1 || true
      pkill -x svim >/dev/null 2>&1 || true
      echo "svim is installed but Accessibility access is not granted."
      echo "Run: just access-request"
    fi

_start-service:
    #!/bin/zsh
    set -euo pipefail

    domain="gui/$(id -u)"
    service="$domain/{{label}}"
    plist="$HOME/Library/LaunchAgents/{{label}}.plist"
    svim="$HOME/.local/bin/svim"

    if [[ ! -x "$svim" || ! -f "$plist" ]]; then
      echo "svim is not installed; run: just install" >&2
      exit 1
    fi

    if ! "$svim" --check-access; then
      echo "Accessibility access is not granted; run: just access-request" >&2
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
    svim="$HOME/.local/bin/svim"

    if [[ ! -x "$svim" || ! -f "$plist" ]]; then
      echo "svim is not installed; run: just install" >&2
      exit 1
    fi

    if launchctl print "$service" >/dev/null 2>&1; then
      launchctl bootout "$service"
    fi

    pkill -x svim >/dev/null 2>&1 || true

    if ! "$svim" --check-access; then
      echo "Accessibility access is not granted; run: just access-request" >&2
      exit 1
    fi

    # Give the previous process a moment to release SketchyVim's lock file.
    for _ in {1..20}; do
      pgrep -x svim >/dev/null 2>&1 || break
      sleep 0.05
    done

    launchctl bootstrap "$domain" "$plist"
    echo "svim restarted"

_restart-upstream-watch:
    #!/bin/zsh
    set -euo pipefail

    domain="gui/$(id -u)"
    service="$domain/{{watch_label}}"
    plist="$HOME/Library/LaunchAgents/{{watch_label}}.plist"
    watcher="$HOME/.local/bin/svim-upstream-watch"

    if [[ ! -x "$watcher" || ! -f "$plist" ]]; then
      echo "svim upstream watcher is not installed; run: just upstream-watch-install" >&2
      exit 1
    fi

    if launchctl print "$service" >/dev/null 2>&1; then
      launchctl bootout "$service"
    fi

    launchctl bootstrap "$domain" "$plist"
    echo "svim upstream watcher loaded (every 6 hours)"
