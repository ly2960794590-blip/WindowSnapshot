# WindowSnapshot (`wsnap`)

[![CI](https://github.com/ly2960794590-blip/WindowSnapshot/actions/workflows/ci.yml/badge.svg)](https://github.com/ly2960794590-blip/WindowSnapshot/actions/workflows/ci.yml)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[中文说明](README.zh-CN.md)

Save your Mac's whole window layout before a reboot or a macOS update, and put it back afterwards
with one command.

macOS reopens your apps after a restart, but it piles the windows onto one desktop: full-screen
apps come back as ordinary windows, Split Views are gone, and browser windows land on the wrong
desktop. `wsnap` records the layout and rebuilds it:

- which **desktop (Space)** each window is on, on **every display**
- which windows are **full screen**, and in what order the full-screen spaces sit in Mission Control
- which two windows share a **Split View**
- the **position and size** of ordinary windows
- for **Chrome and Safari**: every window's tabs, the active tab, and the **profile** it belongs to

> **Status: early.** It has been run on one Mac so far (macOS 27, see
> [Tested on](docs/LIMITATIONS.md#tested-on)). Run `wsnap doctor` first; it tells you what works
> on yours. Reports from other machines are very welcome.

## What it looks like

```
$ wsnap backup
Snapshot of 2026-11-22 17:27:39, macOS 27.2.1

[Main display] 1352×878
  Desktop 1
      Notes “Shopping list”  at (120,80) size 700×600
  Desktop 2
      Chrome [Personal], 1 tab(s)  at (6,36) size 664×834
          - Inbox - Gmail
      Chrome [Work], 2 tab(s)  at (679,37) size 665×834
          - Project plan - Google Docs
          - Example Domain
  Full screen
      Chrome [Shopping], 1 tab(s)  at (0,29) size 1352×849
          - Example Domain
  Split View
      left:  Safari [Work], 1 tab(s)  at (0,29) size 674×849
          - Apple
      right: Notes “Meeting”  at (678,29) size 674×849

[External display] 1920×1080
  Desktop 1
      Xcode “MyApp — MyApp.xcodeproj”  at (-24,-1034) size 1352×849
  Full screen
      Safari [Personal], 1 tab(s)  at (-278,-1080) size 1920×1080
          - Example Domain

Saved: ~/Library/Application Support/WindowSnapshot/snapshots/20261122-172739.json
```

(Example output with made-up window names.)

After the reboot:

```
$ wsnap restore
```

It counts down five seconds, then opens every window, switches desktops for you, and rebuilds
the full-screen spaces and Split Views. Keep your hands off the mouse and keyboard while it runs.
At the end it lists anything it could not do.

## Install

With [Homebrew](https://brew.sh):

```sh
brew install ly2960794590-blip/tap/wsnap
```

Homebrew downloads the source and compiles it on your Mac (about a minute), so there is no
unsigned binary for macOS to block. It needs macOS 13 or later and the Xcode command line tools
(`xcode-select --install`).

<details>
<summary>Or build it yourself</summary>

```sh
git clone https://github.com/ly2960794590-blip/WindowSnapshot.git
cd WindowSnapshot
swift build -c release
cp .build/release/wsnap /usr/local/bin/    # or anywhere on your PATH
```

</details>

Then check your setup:

```sh
wsnap doctor
```

`doctor` lists every capability the tool needs, whether it is available on this Mac, and how to
fix what is not. The two permissions it needs are:

- **Accessibility** for the terminal app you run it from (System Settings → Privacy & Security →
  Accessibility). Needed to move, resize, tile and full-screen windows.
- **Automation** for Chrome and Safari. macOS asks the first time.

To restore several desktops, the Mission Control shortcuts "Move left a space" and "Move right a
space" must be switched on (System Settings → Keyboard → Keyboard Shortcuts → Mission Control).
Any key combination works; `wsnap` reads which keys you chose.

## Usage

| Command | What it does |
|---|---|
| `wsnap backup` | Save the current layout |
| `wsnap backup --name work` | Save it as a named layout, so you can keep several |
| `wsnap restore` | Restore the newest snapshot |
| `wsnap restore work` | Restore a named layout or a given snapshot |
| `wsnap restore --dry-run` | Print every step without touching any window |
| `wsnap restore --yes` | Skip the five-second countdown |
| `wsnap list` | List saved snapshots |
| `wsnap show [SNAPSHOT]` | Print what a snapshot contains |
| `wsnap doctor` | Check what works on this Mac |

Snapshots are plain JSON files in `~/Library/Application Support/WindowSnapshot/snapshots/`.
They contain your window titles and tab URLs, and they never leave your Mac: `wsnap` makes no
network requests.

Output is in English or Chinese following the system language (`WSNAP_LANG=en` or `zh` to force
one). `WSNAP_DEBUG=1` prints what the tool is doing step by step.

## How it works

macOS has no public API for Spaces, so `wsnap` combines three things:

1. Five undocumented system functions to *read* which Spaces exist and which window is on which.
   They are isolated in one file, looked up at runtime, and each has a fallback.
2. The public Accessibility and AppleScript APIs to open, move and resize windows and to read
   browser tabs.
3. For what no API can do (switching desktops, building a Split View, ordering full-screen
   spaces), it operates the same menus and shortcuts a person would.

The details, including the trick that puts a full-screen window at a chosen place in Mission
Control, are in [docs/LIMITATIONS.md](docs/LIMITATIONS.md).

## What it cannot restore

- Unsaved content inside a page or document, and sign-ins that have expired.
- The divider position of a Split View (restored 50/50).
- Which document a non-browser app shows; the app is opened and its window placed.
- Chrome tab groups and pinned tabs come back as ordinary tabs.

Full list: [docs/LIMITATIONS.md](docs/LIMITATIONS.md).

## Contributing

The most useful contribution right now is trying it on your Mac. If something does not work,
open an issue with the output of `wsnap doctor` and, if you can, `WSNAP_DEBUG=1 wsnap restore
--dry-run`. Check the output for anything private (window titles, profile names) before posting.

```sh
swift test    # unit tests for the pure logic in Sources/WSnapCore
```

## License

[MIT](LICENSE)
