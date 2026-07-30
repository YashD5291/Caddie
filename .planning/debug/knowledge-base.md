# GSD Debug Knowledge Base

Resolved debug sessions. Used by `gsd-debugger` to surface known-pattern hypotheses at the start of new investigations.

---

## dock-icon-does-not-reopen-main-window — Dock click / launch does not open the main window under MenuBarExtra(.menu)
- **Date:** 2026-07-10
- **Error patterns:** dock icon, reopen, main window, MenuBarExtra, menuBarExtraStyle(.menu), openWindow, applicationShouldHandleReopen, onAppear, hasVisibleWindows, window does not open, auto-open at launch, activation policy, .accessory, UIElement
- **Root cause:** Two layers. (1) applicationShouldHandleReopen preferred makeKeyAndOrderFront on a closed SwiftUI single-Window scene instead of unconditionally driving openWindow(id:"main"). (2) DEEPER: under `.menuBarExtraStyle(.menu)` the MenuBarExtra CONTENT view is instantiated lazily (only on first menu-bar click), so its `.onAppear` never fires at launch. The openWindowAction capture and the one-time launch auto-open lived in the content view's `.onAppear`, so the main window never auto-opened at launch and openWindowAction stayed nil — making the reopen handler a silent no-op on Dock clicks until the user first clicked the menu bar icon (which armed the action and opened the window — the user's workaround).
- **Fix:** Moved both `openWindowAction = openWindow` and the `hasOpenedMainWindow` launch auto-open into an `.onAppear` on the MenuBarExtra LABEL (renders at launch). Wrapped the status-icon switch in a Group so `.onAppear` can attach. Made the reopen handler nil-check explicit with a CaddieLogger warning (no silent failure). Verified empirically: fresh launch auto-opens window (count 1), 5/5 close→reopen cycles reopen reliably. Note: pre-existing windowWillClose `.accessory` toggle (Foreground→UIElement) removes the dock icon after close — deferred UX decision, not changed.
- **Files changed:** Sources/App/CaddieApp.swift
---
