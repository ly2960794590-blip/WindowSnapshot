# How it works, and what it cannot do

## Undocumented macOS calls

macOS has no public API for Spaces. Five undocumented functions are used, all in
[`Sources/wsnap/PrivateAPI.swift`](../Sources/wsnap/PrivateAPI.swift) and nowhere else:

| Function | Used for | Without it |
|---|---|---|
| `CGSMainConnectionID`, `CGSCopyManagedDisplaySpaces` | List desktops and full-screen spaces per display | Only the windows visible right now are recorded, as one desktop per display |
| `CGSCopySpacesForWindows` | Know which desktop a window is on | Same as above |
| `_AXUIElementGetWindow` | Match accessibility windows to system windows | Chrome profiles are not recorded; Split View and ordered full screen are skipped |
| `_AXUIElementCreateWithRemoteToken` | Reach windows on other desktops | Same, for windows that are not on the current desktop |

They are looked up at runtime (`dlsym`), not linked. If a future macOS removes one, the tool
still starts and turns off only what depended on it. `wsnap doctor` shows which are available;
`WSNAP_NO_PRIVATE_API=1 wsnap doctor` simulates all of them being gone.

Consequences: this cannot be distributed through the Mac App Store, and a major macOS release
may need a fix before everything works again.

## Things done through the user interface

Some results have no API at all, public or private, so the tool operates the same controls a
person would:

- **Switching desktops**: presses your own "Move left/right a space" shortcuts (read from System
  Settings, whatever keys you chose) and checks after each press that the switch happened.
- **Split View**: chooses *Window → Full Screen Tile → Left of Screen* for the left window, then
  clicks the thumbnail of the right window. The menu item is found by its identifier, not its
  translated name.
- **Order of full-screen spaces**: a plain "enter full screen" always lands after every other
  space. A tiled space lands right after the current desktop, so a full-screen window is paired
  with a throw-away helper window, and the helper is closed.
- **Chrome profiles**: Chrome can only be asked for a profile by its folder name, which other
  apps may no longer read from disk. The tool opens `chrome://version` in a tab of that window
  for a moment and reads the profile path from it. Once per profile, then cached.
- **Safari profiles**: opened through *File → New Window → New ‹Profile› Window*, addressed by
  menu position.

Do not use the mouse or keyboard while a restore is running.

## Not restored

- Anything unsaved inside a page or document, and sign-ins that expired.
- Windows the browsers do not expose to scripting, such as a video playing in full screen.
- The divider position of a Split View (it is restored 50/50).
- An app that is already in full screen when restore starts is left where it is; if that puts
  the spaces in a different order than the snapshot, restore says so.
- Per-window state of apps other than Chrome and Safari: the app is opened and its window is
  moved and resized, but which document it shows is up to the app.
- Chrome tab groups and pinned tabs come back as ordinary tabs.

## Requirements

- macOS 13 or later is the build target, but only macOS 27 has actually been run (see below).
  Split View and ordered full screen need the *Full Screen Tile* menu items (macOS 15+) and fall
  back to plain full screen without them.
- Accessibility permission for the terminal app that runs `wsnap`.
- Automation permission for Chrome and Safari (macOS asks on first use).
- For restoring several desktops: the "Move left/right a space" shortcuts must be enabled.

## Tested on

One machine so far: a MacBook with an external 4K display, macOS 27.2, Chinese system language,
Stage Manager on. Split View and ordered full screen were exercised with Chrome windows only.
Nothing has been run on macOS 13, 14 or 15, or on an English system. Please run `wsnap doctor`
and open an issue with its output if something does not work on yours.
