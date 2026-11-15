# XSwitcher

Switch macOS desktops (Spaces) instantly, with no sliding animation, from
the keyboard or the trackpad. It's tiny: the part that stays running uses
about 7 MB of memory.

> **Where this comes from:** XSwitcher is based on
> [InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) by
> **jurplel**, released under the MIT License. The trick that skips the
> animation (a synthetic trackpad swipe, including the macOS 27 event
> format) is jurplel's work, ported to C here. See [LICENSE](LICENSE).
> Thank you, jurplel!

## What's different from InstantSpaceSwitcher

| | InstantSpaceSwitcher 3.1 | XSwitcher |
|---|---|---|
| Memory while running | about 15 MB or more | **about 7 MB** (17 MB more if you turn on the menu bar icon) |
| Menu bar icon | always on | off by default; open the app to get Settings |
| Ctrl+← / Ctrl+→ | you must turn off macOS's shortcuts first ([#46](https://github.com/jurplel/InstantSpaceSwitcher/issues/46)) | **takes them over directly**, nothing to change in System Settings |
| Update checker | not built yet ([#1](https://github.com/jurplel/InstantSpaceSwitcher/issues/1)) | built in (checks this project's GitHub releases) |
| Trackpad gesture turned off on macOS 27.2 | stops working without saying why ([#114](https://github.com/jurplel/InstantSpaceSwitcher/issues/114)) | Settings shows a warning and a button to fix it |
| Settings window | stays in memory once opened | closes completely; only the 7 MB switcher keeps running |

The switching itself is the same speed in both apps, because macOS does that
part. XSwitcher is lighter and stays out of the way.

## Install

```sh
make install          # builds and copies XSwitcher.app to /Applications
open /Applications/XSwitcher.app
```

Then, in the Settings window:

1. Click **Allow…** and turn on **XSwitcher** under Privacy & Security →
   Accessibility.
2. Turn on **Open at login**.

The defaults are **Ctrl+←** and **Ctrl+→**. Click any shortcut to change it,
press **Esc** to cancel or **Delete** to clear it. macOS keeps ⌃← / ⌃→ to
itself while recording, so use **Restore Defaults** to set those.

To get back to Settings later, open XSwitcher again from Applications or
Spotlight.

### Signing (optional, recommended)

Put your code-signing certificate in a `local.mk` file next to the Makefile
(it's git-ignored):

```make
SIGN_ID = Developer ID Application: Your Name (TEAMID)
```

`security find-identity -v -p codesigning` lists the ones you have. With a
certificate, the build uses the hardened runtime and a secure timestamp, and
macOS keeps the Accessibility permission across updates.

### Notarizing a release

With a Developer ID certificate, `make notarize` sends the app to Apple,
staples the approval ticket and writes `build/XSwitcher-<version>.zip`,
ready to attach to a GitHub release. It needs your Apple login saved once:

```sh
xcrun notarytool store-credentials xswitcher-notary --team-id <TEAMID>
```

It asks for your Apple ID and an app-specific password (account.apple.com →
Sign-In and Security → App-Specific Passwords). Your developer account must
have accepted Apple's latest agreement at developer.apple.com/account.

## How it works

XSwitcher.app is one app with one permission entry and one login item:

- **The switcher** (C, about 7 MB) is the app's main program
  (`Contents/MacOS/xswitcher-agent`). It listens for your shortcuts and
  swipes and does the switching. It never loads AppKit and sleeps until you
  press a shortcut. It also answers Finder and Spotlight: opening XSwitcher
  opens Settings.
- **XSwitcher Settings** (Swift/AppKit, in `Contents/Helpers`) is the
  Settings window and the optional menu bar icon. It needs no permission of
  its own, and it quits when you close the window unless the menu bar icon is on.

They share a plain text settings file at `~/.config/xswitcher/config`, which
you can also edit by hand. After editing, reload with:

```sh
kill -HUP $(pgrep -x xswitcher-agent)
```

## Updates

The app checks this project's GitHub releases once a day. Set the repo when
building:

```sh
make install UPDATE_REPO=your-github-name/xswitcher
```

Then publish a GitHub release whose tag is the version number (e.g. `v0.3.0`).

## Known limits

- **Permissions after updates:** macOS ties the Accessibility permission to
  the app's signature. Builds signed with a real certificate keep it across
  updates. Ad-hoc builds (the default without a certificate) look like a new
  app every time, so you have to turn it on again after each rebuild. Opening
  the app after an update also re-registers "Open at login" if needed.
- **macOS 27.2 and later** need the trackpad's "swipe between full-screen
  apps" gesture turned on. Settings warns you if it's off.
- Dragging a window while switching doesn't carry it along (same as upstream
  [#29](https://github.com/jurplel/InstantSpaceSwitcher/issues/29)).

## Project layout

```
agent/    the switcher, XSwitcher.app's main program (C)
app/      XSwitcher Settings: Settings window and menu bar icon (Swift/AppKit)
bundle/   Info.plist files for the app and the Settings helper
Makefile  `make`, `make install`, `make clean`
```

## License

MIT. Copyright (c) 2026 jurplel for the original InstantSpaceSwitcher code;
see [LICENSE](LICENSE).
