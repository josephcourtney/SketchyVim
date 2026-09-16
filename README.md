# SketchyVim
This small project turns accessible(!) input fields on macOS into full vim
buffers. It should behave and feel like native vim, because, under the hood
I synchronize the text field with a real vim buffer.

![demo](https://user-images.githubusercontent.com/22680421/153753171-e818d40b-4d88-9719-d1e36d16dec0.gif)

You can use all modes (even commandline etc.) and all commands included in vim.

It is also possible to load a custom `svimrc` file, which can contain
custom vim configurations, e.g. remappings (see the examples folder).

Additionally, you can edit the `blacklist` file in the `~/.config/svim/` folder
to manually exclude applications from being handled by svim.
You will likely want to blacklist your terminal emulator and gvim, such that there
is no conflict. Entering a blacklisted application clears SketchyVim's current
accessibility/Vim state immediately; subsequent key events are passed through
unchanged.

SketchyVim can also be temporarily bypassed without clearing its current Vim mode
or buffer state. This is useful for system-wide modal key interfaces that need
exclusive access to unmodified keys while active:

```bash
# Temporarily pass all key events through SketchyVim unchanged.
pkill -USR1 svim

# Resume normal SketchyVim handling.
pkill -USR2 svim
```

Every time the vim mode changes, or a commandline update is issued, the script
`svim.sh` in the folder `~/.config/svim/` is executed where you can handle 
how you want to process this information. I have a small popup in my [SketchyBar](https://github.com/FelixKratz/SketchyBar)
which shows me the command line output on demand for example.

(!): Accessible means, that the input field needs to conform to the accessibility
     standards for text input fields, else there is nothing we can do.

## Installation
You can install this using brew from my tap:
```bash
brew tap FelixKratz/formulae
brew install svim
```
and then you can start the brew service using:
```
brew services start svim
```
where you will be asked to grant accessibility permissions.

For this fork, the repository also includes a `justfile` that builds the patched
binary and manages it as a user LaunchAgent:

```bash
just install
just status
just update
```

The installed executable is kept at `~/.local/bin/svim`, so rebuilding the checkout
does not disturb the running service. The local service is code-signed with a
persistent identity so Accessibility permission survives rebuilds.

### Keeping the fork current with upstream

The fork is maintained as a small patch stack on top of
`FelixKratz/SketchyVim`. To see whether upstream has advanced:

```bash
just upstream-check
```

To rebase the local patch stack onto current upstream, rebuild, sign, install, and
restart:

```bash
just sync-upstream
```

After reviewing the result, update this GitHub fork with lease protection:

```bash
just push-upstream-sync
```

or perform both operations with:

```bash
just sync-upstream-push
```

A scheduled GitHub Actions workflow performs the same rebase and build as a
validation check. When upstream advances and the patch stack still applies, it
opens or updates `automation/upstream-sync` as a review PR. The PR is deliberately
a review/CI surface rather than a merge target because accepting an upstream sync
requires rewriting the fork's patch commits. If the automated rebase conflicts,
the workflow opens or updates an issue instead.

### Local upstream update notifications

`just install`, `just update`, and `just sync-upstream` also install a second user
LaunchAgent, `com.josephcourtney.svim-upstream-check`. It runs once when loaded and
then every six hours. The watcher fetches upstream and compares `upstream/master`
with the fork's local `master` branch.

When upstream contains commits that local `master` does not yet contain, the
watcher sends a macOS notification. It prefers Hammerspoon notifications when the
`hs` CLI is available and falls back to `osascript`. A particular upstream commit
only generates one notification; the remembered SHA is stored in
`~/.local/state/svim/upstream-notified` and is cleared after the fork catches up.

Useful watcher commands are:

```bash
just upstream-watch          # run one check now
just upstream-watch-status   # show the six-hour LaunchAgent state
just upstream-watch-logs     # follow watcher stdout/stderr
just upstream-watch-install  # reinstall/reload it, e.g. after moving the repo
just upstream-watch-stop     # stop only the watcher
```

Each check also emits the optional SketchyBar event `svim_upstream_update` when
`sketchybar` is available. Subscribers receive `available=1`, `count`, and `sha`
when an update is pending, or `available=0` after the fork catches up. Existing
SketchyBar configurations that do not subscribe to this event are unaffected.

You can change the macOS selection color to anything you like with this command (which is my green):
```bash
defaults write NSGlobalDomain AppleHighlightColor -string "0.615686 0.823529 0.454902"
```

## Issues
Please tell me if you encounter issues.

Known Issues:
-------------
* Multikey remappings are not recognized (e.g. jk for esc)
* Some text fields break the accessibility api and this leads to bugs,
  be sure to blacklist all apps that are affected by this.
  Sometimes it helps to switch to a "raw" or "markdown" editing mode on websites,
  such that there is no interference.
  Generally, Safari seems to make most text fields available, while Firefox does not.
* Comments in svimrc break the config (#18)

## Contributions
Pull requests are welcome. If you improve the code for your own use, consider creating
a pull request, such that all people (including me) can enjoy those improvements.

## Credits
* I use the libvim library which is a compact and minimal c library for the vim core.
* Many prior projects tried to accomplish a similar vision by rebuilding the vim
  movements by hand, those have inspired me to create this project.
