# HopKey

**Search or click an app to hop to.**

An overlay plugin for the Omarchy Quattro shell. The window you want is already
open — it's just on another workspace, another monitor, or buried three deep in
the tile stack. HopKey gets you there in one hop: hit the key, type a couple of
letters, press Enter, and you're on that window instead of cycling through
Alt-Tab.

With Chrome, Grok, Claude Code, VS Code and LibreOffice open, `Ch` + Enter hops
to Chrome. Hyprland switches workspaces on the way if the window is on another
one.

## Requirements

- Omarchy with the Quattro shell (`omarchy-shell`). HopKey is an `overlay`
  plugin and runs inside that shell; it never starts a Quickshell process of
  its own.
- Hyprland, Omarchy's compositor. Workspace labels, recent-window order,
  thumbnails, workspace previews and workspace switching all come from it.

There are no other dependencies: nothing to install, no services, and no
root access.

## What it does on your system

HopKey is unsandboxed code in your shell session, like every Omarchy plugin,
so here is everything it touches:

- **Reads** the open-window list (Wayland toplevel manager), Hyprland's
  window, workspace and monitor data, and your desktop entries for app names
  and icons.
- **Captures window contents** for the thumbnails and workspace previews,
  using Hyprland's toplevel export. Each capture is one still frame held in
  memory while the overlay is open. Nothing is written to disk or sent
  anywhere.
- **Runs one command**: `hyprctl dispatch` to switch workspace when you pick a
  workspace row. The workspace name is passed as a single argument, never
  through a shell.
- **Writes nothing.** HopKey does not edit your configuration. The key binding
  and menu entry below are changes you make yourself.

## Install

```sh
omarchy plugin add https://github.com/rtbhhi/hopkey.git --enable
```

Then bind it in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + Q", "HopKey",
  "omarchy-shell shell toggle io.github.rtbhhi.hopkey")
```

`SUPER + Q` is unbound in stock Omarchy — closing a window is `SUPER + W` — so
there is nothing to unbind first. Any free combination works; pick the one your
hand finds without looking, because that is the whole point.

Optionally add it to the `Super + Space` menu, by creating or extending
`~/.config/omarchy/extensions/omarchy-menu.jsonc`:

```jsonc
{
  "hopkey": {
    "icon": "󰖯",
    "label": "HopKey",
    "aliases": ["window", "switch", "jump"],
    "action": "omarchy-shell shell toggle io.github.rtbhhi.hopkey"
  }
}
```

Only whole-line `//` comments are stripped from that file, and a file that
fails to parse drops every user menu entry, so keep it valid JSON.

## Usage

| Key | Action |
|---|---|
| Type | Filter the list |
| `Enter` | Hop to the selected window |
| `Up` / `Down`, `Tab` / `Shift+Tab` | Move the selection |
| `PageUp` / `PageDown`, `Home` / `End` | Move further |
| `Escape` | Clear the filter, or close when it is already empty |
| Click | Hop to that window |

Matching ranks an app-name prefix above a word inside a title, and a loose
subsequence last, so short queries land where you expect. Before you type, and
between equally good matches, windows are listed most recently used first. The
window you opened HopKey from goes last, so the bind then Enter flips you back
to the window you were in before it. Web apps match on
their site name: `gr` finds Grok even though its window class is
`chrome-grok.com__-Default`.

### Workspaces

Type a workspace number, like `3`, and that workspace leads the list. Its
windows are grouped underneath it, and Enter takes you to the whole workspace.
`w3`, `ws 3` and `workspace 3` work too, and named workspaces match by name
(`ws comms`). A number that has no workspace yet shows as an empty workspace,
and Enter creates it, as Hyprland always does.

A workspace row shows a miniature of its monitor, with each window drawn
where it actually sits and floating windows on top, plus a count of its
windows and the apps on it. Special (scratchpad) workspaces are not listed.

### Rows

Each row shows the window title, with its app and workspace underneath. The
top three matches also show a snapshot of the window, so you can see where
you are about to hop to before you press Enter. The rest stay as plain text.

## How it works

Workspace switches go through `hyprctl dispatch`, in the Lua syntax Omarchy's
config uses (`hl.dsp.focus({ workspace = "3" })`) or the classic syntax on a
non-Lua config.

Snapshots come from Quickshell's `ScreencopyView`, using Hyprland's toplevel
export. Each one is a single still frame, not a live feed, and it is
recaptured when the filter changes. If a window can't be captured, its row
shows the app icon instead.

The window list comes from the Wayland toplevel manager, so it tracks windows
live while the overlay is open rather than sampling once. Workspace labels are
read from Hyprland when available and omitted if that mapping is not.

The overlay drops its layer surface before it activates the window, so the
compositor is never asked to focus something while HopKey still holds
exclusive keyboard focus.

## Remove

```sh
omarchy plugin remove io.github.rtbhhi.hopkey
```

Then delete the `SUPER + Q` binding from `~/.config/hypr/bindings.lua`, and the
`hopkey` entry from `~/.config/omarchy/extensions/omarchy-menu.jsonc` if you
added one. HopKey keeps no other files or state.

## Development

```sh
node test/model-test.js
omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" Overlay.qml
```

`Model.js` holds the matching logic as plain JavaScript that both QML and Node
can load, following `shell/plugins/menu/MenuModel.js` in Omarchy itself, so the
ranking is tested without a running shell.

Saving a plugin file reloads HopKey, but the shell caches imported JavaScript,
so changes to `Model.js` only take effect after `omarchy-restart-shell`.

## License

MIT. See [LICENSE](LICENSE).
