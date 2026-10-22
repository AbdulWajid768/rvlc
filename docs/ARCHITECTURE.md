# Architecture overview

```
┌────────────────────────────── RVLCPlayer (executable) ──────────────────────────────┐
│ main.swift → RVLCApplication.run()                                                 │
└──────────────────────────────────────┬─────────────────────────────────────────────┘
                                       │
┌──────────────────────────── RVLCApp (AppKit UI) ─────────────────────────────┐
│ AppDelegate ─ menus, windows, lifecycle, --self-test / --export-iconset       │
│ PlayerController ─ single implementation of every action (menus, buttons,     │
│                    keys all call it); playlist, resume, per-file sync memory  │
│ SubtitleSession ─ Subtitle Studio state: document, preview track, sync        │
│                   points, suggestions (preview/apply/discard), undo, export   │
│ KeyboardRouter ─ one NSEvent monitor; text fields/lists keep their keys       │
│ MainWindowController ─ split view: PlayerViewController | SidebarViewController│
│   Player/  ControlBarView, TimelineSlider, overlays (empty, error, OSD)       │
│   Sidebar/ Playlist, Library, Subtitle Studio, Audio Sync Lab, Picture & Sound│
│   Editor/  SubtitleEditorWindowController                                     │
│   Dialogs/ Settings (incl. shortcut recorder), Shortcuts reference, File info │
│   Theme/   design tokens, SF Symbols, programmatic app icon                   │
└──────────────┬───────────────────────────────────────────┬───────────────────┘
               │                                           │
┌──────────────▼───────────── RVLCEngine ─────────┐  ┌─────▼──────── RVLCCore ───────────────┐
│ MPVPlayer: libmpv handle, event loop on a      │  │ Subtitles/ model, SRT, WebVTT, ASS,    │
│   private queue → @Published state on main;    │  │   encodings, export, SyncFit (offset/  │
│   commands, tracks, delays, filters            │  │   drift), AutoSync (vDSP), editing     │
│ MPVVideoView/MPVVideoLayer: OpenGL render API  │  │ Library/ MediaLibrary (JSON store),    │
│ AudioExtractor: headless libmpv, ao=pcm        │  │   Playlist                             │
│ AudioEffects / VideoAdjustments → mpv props    │  │ Settings/ Preferences, KeyMap          │
└──────────────┬─────────────────────────────────┘  └───────────────────────────────────────┘
               │
         CMpv (system library: libmpv via pkg-config)
```

## Principles

- **The engine is the source of truth.** UI state (play/pause icon, time,
  offsets, tracks) is derived from libmpv events, never from what the UI
  assumes happened. Relative adjustments read the current value synchronously
  from libmpv so rapid key presses never lose steps.
- **One action, one implementation.** `PlayerController.perform(_:)` is the only
  place a player action is implemented. Buttons refuse first responder so a
  click never leaves a button focused for Space to re-trigger.
- **Pure logic is testable without UI or engine.** `RVLCCore` depends only on
  Foundation and Accelerate.
- **Never modify user files.** Subtitle preview files live in
  `~/Library/Caches/RVLC/Subtitle Preview`; exports refuse to overwrite
  the source and are written atomically.

## Threading

- libmpv's wakeup callback (holding only a weak reference to the player)
  schedules event draining on a serial queue; decoded events are applied on the
  main thread.
- Every `loadfile` records libmpv's `playlist_entry_id`; start/loaded/end
  events of superseded files are ignored, so pressing Next twice quickly never
  attributes one file's events or metadata to another.
- All drawing — libmpv update callbacks and Core Animation redraws during
  resizing or full-screen transitions — is serialised on one render queue, as
  libmpv's render API requires. The OpenGL context and libmpv render context are
  created eagerly so a file opened at launch always gets video output.
- Audio analysis runs on a global queue with cancellation.
- Shutdown order: free the render context, then destroy libmpv. After shutdown
  every `MPVPlayer` call is a safe no-op.

## Persistence

| Data | Location |
|---|---|
| Preferences (theme, steps, shortcuts, subtitle style, …) | `UserDefaults` (`org.rvlc.player`) |
| Library: history, resume positions, favourites, per-file audio delay and subtitle choice/offset, playlist | `~/Library/Application Support/RVLC/library.json` (atomic writes; unreadable files are backed up, not discarded) |
| Subtitle preview files | `~/Library/Caches/RVLC/Subtitle Preview` (deleted when no longer used) |

## Adding a feature

1. Put format/maths logic in `RVLCCore` with unit tests.
2. Expose engine capabilities in `RVLCEngine` and cover them with an
   integration test against the real backend.
3. Add the action to `PlayerAction` (if it deserves a shortcut) and implement it
   once in `PlayerController`.
4. Build the UI from the components in `Components/Controls.swift`.
