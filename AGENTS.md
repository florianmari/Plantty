# AGENTS.md

Notes for coding agents working on Plantty, a native macOS terminal (SwiftUI + AppKit) built on libghostty. Read `README.md` for what the app does.

## Build and test

```sh
./scripts/build-ghostty.sh   # once: builds vendor/GhosttyKit.xcframework + vendor/share (zig 0.16, several minutes)
xcodegen generate            # after adding/removing files or editing project.yml
xcodebuild -project Plantty.xcodeproj -scheme Plantty -derivedDataPath build build
xcodebuild -project Plantty.xcodeproj -scheme Plantty -derivedDataPath build test
open build/Build/Products/Debug/Plantty.app
```

- `Plantty.xcodeproj` is generated from `project.yml`; never edit it by hand. It is gitignored, along with `vendor/` and `build/`.
- New Swift files under `Plantty/` are picked up automatically, but only after `xcodegen generate`.
- SourceKit shows "No such module 'GhosttyKit'" and "Cannot find type" errors until the project has been generated and built. Trust `xcodebuild`, not those diagnostics.
- The app is arm64 only (`ARCHS: arm64`), because libghostty is built with `-Dxcframework-target=native`.
- Language mode is Swift 5 with minimal concurrency checking. libghostty's C callbacks don't fit Swift 6 isolation.

## Layout

```
Plantty/Ghostty/GhosttyApp.swift   the libghostty app: config loading, runtime callbacks, action routing, clipboard
Plantty/Ghostty/SurfaceView.swift  the NSView for one terminal: sizing, focus, mouse, keyboard/IME (ported from Ghostty)
Plantty/Model/Workspace.swift      @Observable state: projects → tabs → panes, live surfaces, persistence
Plantty/Model/SplitNode.swift      pure split-tree value type + its saved (Codable) form — unit tested
Plantty/UI/                        SwiftUI views: ContentView (+Theme, WindowChrome), Sidebar, TabBar, SplitContainer, PaneView, CommandPalette
PlanttyTests/                      XCTest; compiles SplitNode.swift directly, so tests don't start libghostty
scripts/                           build-ghostty.sh, make-icon.swift
```

## How it fits together

- **One libghostty app, many surfaces.** `GhosttyApp.shared` owns the `ghostty_app_t`. Each pane is a `SurfaceView` that owns a `ghostty_surface_t`, which is freed in the view's `deinit`.
- **Workspace owns the views.** `Workspace.surfaces[paneID]` keeps terminals alive while their tab is hidden, which keeps tab switching instant. `SplitNode` stores only pane UUIDs.
- **Callbacks hop to main.** libghostty can call back off the main thread, or re-entrantly while a surface is being created inside `Workspace.init`. Every model change from a callback goes through `onMain { }`, which always dispatches asynchronously. Keep it that way.
- **Ghostty keybinds win.** `SurfaceView.performKeyEquivalent` sends keys that match a Ghostty binding to the terminal. The resulting action arrives in `GhosttyApp.handle` and calls the same `Workspace` method the menu item would. When you add a shortcut, handle both paths: the SwiftUI menu in `PlanttyApp.swift` and the action case in `GhosttyApp.handle`.
- **PaneView ownership.** During layout changes SwiftUI briefly keeps an old `PaneHost` next to the new one. Only `surface.owner` may hold the surface, or the remaining pane gets detached (the ⌘W-on-a-split bug). Don't simplify this away.
- **Theme follows the user's Ghostty config.** `Theme` reads the background color and `background-opacity`. When the window is see-through, nothing may draw behind the terminals, or the opacities stack.

## Persistence

- State lives in `~/Library/Application Support/Plantty/projects.json`. The format is `Workspace.Saved`, with tab layouts as `SavedLayout`.
- Keep old files loading: add optional fields only, and keep case and field names. An unreadable file is moved to `projects.json.bad`, never overwritten.
- Settings are in `UserDefaults` (`dev.plantty.Plantty`): `tabStyle` and `restoreSession`.
- Before experiments that change state, back up `projects.json` and restore it afterwards. It is the user's real session.

## Conventions

- Smallest change that fully works. Match the surrounding code; comment only the *why*.
- A deliberate limitation gets a `// shortcut: <limit>, <when to upgrade>` comment.
- Logic that can be pure goes in a value type with a test, as `SplitNode` and `SavedLayout` do.
- Files adapted from Ghostty keep their MIT notice header.
- Pin Ghostty by commit (`GHOSTTY_COMMIT` in `scripts/build-ghostty.sh`). The embedding C API (`vendor/ghostty/include/ghostty.h`) changes often, so check it after any bump. To rebuild, delete `vendor/GhosttyKit.xcframework` first.

## Verifying UI changes

- Launch the Debug app and take a screenshot of the window. Get its ID from `CGWindowListCopyWindowInfo` and pass it to `screencapture -l<id>`. This needs Screen Recording permission for the host terminal.
- Sending keystrokes with `osascript`/System Events needs Accessibility permission. If you don't have it, drive the app with a temporary harness: an env var checked in `applicationDidFinishLaunching` that calls `Workspace` methods or `SurfaceView.runAction("new_split:right")`. Delete the harness before committing.
- Run the tests before every commit.

## Releasing

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Run `xcodebuild ... -configuration Release build`.
3. Zip with `ditto -c -k --keepParent`. For the DMG, put the `.app` and an `Applications` symlink in a folder and run `hdiutil create -format UDZO`.
4. Run `gh release create vX.Y.Z Plantty.dmg Plantty.zip`.

Builds are ad-hoc signed and not notarized. The README tells users how to open them anyway.
