#!/bin/zsh
set -euo pipefail

upstream_remote="${SVIM_UPSTREAM_REMOTE:-upstream}"
upstream_url="${SVIM_UPSTREAM_URL:-https://github.com/FelixKratz/SketchyVim.git}"
upstream_branch="${SVIM_UPSTREAM_BRANCH:-master}"
repo="${SVIM_REPO_PATH:-}"
state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/svim"
notified_file="$state_dir/upstream-notified"

if [[ -z "$repo" ]]; then
  repo="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi

if [[ -z "$repo" || ! -d "$repo/.git" ]]; then
  echo "SketchyVim repository not found; set SVIM_REPO_PATH" >&2
  exit 1
fi

if ! git -C "$repo" show-ref --verify --quiet refs/heads/master; then
  echo "SketchyVim master branch not found in $repo" >&2
  exit 1
fi

mkdir -p "$state_dir"

if ! git -C "$repo" remote get-url "$upstream_remote" >/dev/null 2>&1; then
  git -C "$repo" remote add "$upstream_remote" "$upstream_url"
fi

git -C "$repo" fetch --quiet "$upstream_remote" "$upstream_branch"
ref="$upstream_remote/$upstream_branch"
count=$(git -C "$repo" rev-list --count "refs/heads/master..$ref")
sha=$(git -C "$repo" rev-parse "$ref")
short_sha=$(git -C "$repo" rev-parse --short "$ref")

# Emit a custom SketchyBar event on every check so a bar restart can recover the
# current state. Existing configurations that do not subscribe to the event are
# unaffected.
if command -v sketchybar >/dev/null 2>&1; then
  if (( count > 0 )); then
    sketchybar --trigger svim_upstream_update available=1 count="$count" sha="$short_sha" >/dev/null 2>&1 || true
  else
    sketchybar --trigger svim_upstream_update available=0 count=0 sha="$short_sha" >/dev/null 2>&1 || true
  fi
fi

if (( count == 0 )); then
  rm -f "$notified_file"
  echo "upstream: up to date ($short_sha)"
  exit 0
fi

last_notified=""
if [[ -f "$notified_file" ]]; then
  last_notified=$(<"$notified_file")
fi

if [[ "$last_notified" == "$sha" ]]; then
  echo "upstream: $count new commit(s) at $short_sha; already notified"
  exit 0
fi

message="Upstream SketchyVim has $count new commit(s) ($short_sha). Run just sync-upstream-push."

if command -v hs >/dev/null 2>&1; then
  SVIM_UPDATE_MESSAGE="$message" hs -c 'hs.notify.new({title="SketchyVim update available", informativeText=os.getenv("SVIM_UPDATE_MESSAGE")}):send()'
else
  /usr/bin/osascript - "$message" <<'APPLESCRIPT'
on run argv
  display notification (item 1 of argv) with title "SketchyVim update available"
end run
APPLESCRIPT
fi

printf '%s\n' "$sha" > "$notified_file"
echo "upstream: $count new commit(s) at $short_sha; notification sent"
