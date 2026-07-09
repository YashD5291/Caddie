---
status: resolved
trigger: "Clicking the Caddie Dock icon does not open/reopen the main window. Only the menu bar mic icon works. Recurring."
created: 2026-07-09T00:00:00Z
updated: 2026-07-09T00:00:00Z
fix_branch: fix/dock-icon-reopen
fix_commit: 7596a65
---

## Current Focus

hypothesis: DEEPER ROOT CAUSE (orchestrator-confirmed empirically). Under `.menuBarExtraStyle(.menu)`, the MenuBarExtra CONTENT view (MenuBarView) is instantiated lazily — only when the user first clicks the menu bar icon. At launch only the LABEL (the status Image switch) renders. The prior fix put both `openWindowAction = openWindow` AND the `hasOpenedMainWindow` launch auto-open in MenuBarView's `.onAppear`, which never fires at launch. Result: (1) main window never auto-opens at launch, (2) `openWindowAction` stays nil so `applicationShouldHandleReopen` silently no-ops on Dock click until the user clicks the menu bar icon once.
test: Move openWindowAction capture + launch auto-open into `.onAppear` on the LABEL (which renders at launch, AX-confirmed). Add explicit nil-check + warning log in reopen handler. Build + empirically launch/reopen-test the real app.
expecting: Main window auto-opens at launch; window count >=1 after `reopen` Apple event; stable across close/reopen cycles.
next_action: RESOLVED — fix applied, build + 280 tests pass, empirically verified (launch auto-opens; 5/5 reopen cycles). Archived.

## Symptoms

expected: Clicking the Dock icon (re)opens/focuses Caddie's main window like any standard macOS app, including when the window was previously closed.
actual: Multiple Dock icon clicks do nothing visible. Main window only opens via the MenuBarExtra mic icon path.
errors: None reported.
reproduction: Close the main window (or launch app), click the Dock icon repeatedly — window does not appear. Menu bar icon works.
started: Recurring — has happened before. SwiftUI MenuBarExtra + single Window scene app (macOS 14.2, Swift 6).

## Eliminated

- hypothesis: "The reopen handler is missing entirely."
  evidence: applicationShouldHandleReopen is implemented in AppDelegate (CaddieApp.swift:131). Not missing.
  timestamp: 2026-07-09T00:00:00Z

## Evidence

- timestamp: 2026-07-09T00:00:00Z
  checked: CaddieApp.swift scene structure
  found: App uses MenuBarExtra + single Window("Caddie", id:"main") scene. AppDelegate inline. LSUIElement=false so app launches .regular (dock icon present).
  implication: Reopen of a closed single-Window scene must go through SwiftUI openWindow.

- timestamp: 2026-07-09T00:00:00Z
  checked: Menu bar "Open Caddie" button (MenuBarView.swift:66-72)
  found: Does setActivationPolicy(.regular); openWindow(id:"main"); NSApp.activate. Confirmed WORKING by user.
  implication: openWindow(id:"main") is the reliable reopen mechanism.

- timestamp: 2026-07-09T00:00:00Z
  checked: applicationShouldHandleReopen (CaddieApp.swift:131-143)
  found: On !flag, prefers findMainWindow()?.makeKeyAndOrderFront(nil), only falling back to openWindow when window not found.
  implication: For a closed single-Window scene, findMainWindow() returns retained hidden NSWindow, so openWindow fallback never runs; makeKeyAndOrderFront fails to render. Diverges from working menu-bar path.

- timestamp: 2026-07-09T00:00:00Z
  checked: git log prior attempts
  found: b1f910e introduced handler, 5b308ae refactored to findMainWindow, 640cdae added openWindow fallback but kept findMainWindow-first. ef17e7d added .accessory toggling on windowWillClose.
  implication: Recurring — prior fixes never converged on the proven openWindow path.

- timestamp: 2026-07-09T00:00:00Z
  checked: windowWillClose (CaddieApp.swift:170-179)
  found: On close, async Task switches to .accessory if no visible main window; uses isVisible which can race.
  implication: Compounds issue (dock icon can vanish). Using our own isMainAppWindow visibility check in reopen (instead of unreliable flag) is more robust.

- timestamp: 2026-07-10T00:00:00Z
  checked: DEEPER ROOT CAUSE — MenuBarExtra content vs label lifecycle under .menuBarExtraStyle(.menu). Orchestrator empirically tested prior fix (commit 7596a65) on a real launched app and it FAILED: fresh launch showed ZERO windows, and a reopen event still produced zero windows.
  found: Under `.menuBarExtraStyle(.menu)` the MenuBarExtra CONTENT view (MenuBarView) is instantiated LAZILY — only on first menu-bar click. At launch only the LABEL (status Image switch) renders (AX-confirmed: `menu bar item mic.badge.plus`). The prior fix placed BOTH `openWindowAction = openWindow` AND the `hasOpenedMainWindow` launch auto-open in MenuBarView's `.onAppear`, which never fires at launch. So: (1) main window never auto-opens at launch; (2) `openWindowAction` stays nil, making `applicationShouldHandleReopen`'s `openWindowAction?(id:"main")` a silent no-op until the user clicks the menu bar icon once (which is exactly the user's workaround, and explains the recurring/intermittent history).
  implication: The capture + auto-open must live on the LABEL (guaranteed to render at launch), not the lazy content view.

- timestamp: 2026-07-10T00:00:00Z
  checked: EMPIRICAL VERIFICATION of deeper fix on real launched Debug app (branch fix/dock-icon-reopen). App path: ~/Library/Developer/Xcode/DerivedData/Caddie-gaujkvsybzcmwgepbihhspvvoeyo/Build/Products/Debug/Caddie.app
  found: |
    make build => ** BUILD SUCCEEDED **. make test => ** TEST SUCCEEDED ** (280 tests, 0 failures).
    Fresh launch (open <app>, sleep 8): `count windows` = 1 → MAIN WINDOW AUTO-OPENS AT LAUNCH (previously 0). lsappinfo type="Foreground" (dock icon present).
    Close window 1 (click button 1): `count windows` = 0.
    5 consecutive close→reopen cycles via `osascript -e 'tell application "Caddie" to reopen'` (the true Dock-click / applicationShouldHandleReopen equivalent): after close=0, after reopen=1 — ALL 5 cycles reopened reliably (1/1 each).
  implication: Deeper root cause confirmed and fixed. Launch auto-open and Dock reopen both work reliably.

- timestamp: 2026-07-10T00:00:00Z
  checked: Secondary observation on `.accessory` toggle (windowWillClose) impact on the REAL dock icon and on `open -a`.
  found: |
    After closing the window, windowWillClose deterministically switches the app to .accessory — lsappinfo type transitions "Foreground" → "UIElement", i.e., the DOCK ICON IS REMOVED. The `reopen` Apple event still reaches the app and reopens (that is why 5/5 cycles pass when sent directly), but with no dock icon present a user has nothing to click in that state.
    Separately, `open -a Caddie` while the app is in .accessory spawned a SECOND instance (pgrep showed 2) rather than reopening the first — a LaunchServices artifact of the UIElement state, not a Dock-click path.
  implication: The user's reported state ("dock icon PRESENT but does nothing") corresponds to the app remaining .regular after close (the isVisible check races to .regular), and THAT state is now fixed. But the deterministic close→.accessory path removes the dock icon entirely — this is the pre-existing deferred "dynamic dock" behavior (ef17e7d), unchanged by this fix and still a user decision.

## Resolution

root_cause: |
  TWO layers.
  Layer 1 (fixed in commit 7596a65): applicationShouldHandleReopen preferred makeKeyAndOrderFront on a closed SwiftUI single-Window scene instead of unconditionally driving openWindow(id:"main"), and gated on the unreliable `flag`. Converged onto the proven menu-bar openWindow path.
  Layer 2 (DEEPER, this session): Under `.menuBarExtraStyle(.menu)`, the MenuBarExtra CONTENT view (MenuBarView) is instantiated lazily — only on first menu-bar click. At launch only the LABEL renders. The prior fix put both the `openWindowAction = openWindow` capture AND the `hasOpenedMainWindow` launch auto-open in MenuBarView's `.onAppear`, which never fires at launch. Result: main window never auto-opened at launch, and `openWindowAction` stayed nil so the reopen handler silently no-op'd on Dock clicks until the user first clicked the menu bar icon (their workaround) — which armed the action and opened the window. This is why the bug recurred/appeared intermittent.
fix: |
  Moved BOTH `appDelegate.openWindowAction = openWindow` AND the one-time `hasOpenedMainWindow` launch auto-open into an `.onAppear` attached to the MenuBarExtra LABEL (wrapped the status-icon `switch` in a `Group` so `.onAppear` can attach). The label demonstrably renders at launch, so the action is captured and the window auto-opens immediately. Assignment is idempotent; the `hasOpenedMainWindow` guard keeps the auto-open one-time.
  In applicationShouldHandleReopen, replaced the silent `openWindowAction?(id:"main")` with an explicit `guard let openWindowAction else { CaddieLogger.app.warning(...); return true }` (no silent failure, per project rule) — reopen behavior otherwise identical.
  Corrected the now-accurate comments (init note + label note) explaining that the label, not the content view, is the launch-guaranteed seam under .menu style.
verification: |
  make build => ** BUILD SUCCEEDED **. make test => ** TEST SUCCEEDED ** (280 tests, incl. DockReopenTests decision-seam guards).
  EMPIRICAL (real launched Debug app): fresh launch → window count = 1 (auto-opens; was 0); close → 0; 5/5 `reopen`-event cycles reopened the window reliably. See Evidence entries dated 2026-07-10.
files_changed: [Sources/App/CaddieApp.swift]

## Open Follow-up (secondary, needs user decision)

windowWillClose still switches NSApp to .accessory when no main window is visible ("dynamic dock" from ef17e7d). In .accessory the Dock icon is REMOVED, so if that switch fires the Dock affordance disappears entirely (nothing to click). The user's report (Dock icon present but does nothing) indicates that in practice the app is .regular at click time (the isVisible check likely races and leaves it .regular), which the handler fix now covers. If, after this fix, the Dock icon still sometimes vanishes after closing the window, the fully-standard-app behavior would require removing the .accessory switch (keep the app .regular always). That is a deliberate UX change — deferred for user decision rather than ripped out unilaterally.

NEW EVIDENCE (2026-07-10): Empirically confirmed the .accessory switch fires DETERMINISTICALLY on close in the built app — lsappinfo type transitions Foreground → UIElement after closing the window, so the dock icon is removed in that path. The `reopen` Apple event still reopens the window (5/5), but a real user with no dock icon has nothing to click. Also, `open -a Caddie` while .accessory spawned a second app instance (LaunchServices artifact). RECOMMENDATION for the user to decide: for standard "always click the dock icon to reopen" behavior, remove the windowWillClose .accessory switch and keep the app .regular always. Not changed in this session because it is a deliberate UX decision and outside this fix's scope.
</parameter>
</invoke>

## Follow-up Resolved (2026-07-10): Dock icon now always present

**User decision:** Always keep the Dock icon while Caddie runs (standard macOS app behavior). The "dynamic dock" menu-bar-only mode (ef17e7d) is removed.

**Change (Sources/App/CaddieApp.swift):**
- Removed the `windowWillClose` observer + handler that switched `NSApp` to `.accessory` when no main window was visible (this is what deleted the Dock icon after close).
- Removed the `windowDidBecomeKey` observer + handler that existed solely to switch back to `.regular` (dead with the accessory path gone).
- Removed both `NotificationCenter` observer registrations in `applicationDidFinishLaunching` (they existed solely for that pair).
- `Info.plist` has `LSUIElement=false`, so the app is `.regular` from launch natively; with the accessory switch gone the policy is unconditionally `.regular` for the app lifetime. The idempotent `.regular` calls in the verified reopen handler and MenuBarView's Open button are retained unchanged.
- Reopen handler and label-`.onAppear` capture untouched (verified in the previous session).

**Empirical verification (real launched Debug app, fresh single instance):**
- `make build` → `** BUILD SUCCEEDED **`; `make test` → `** TEST SUCCEEDED **` (280 tests, 0 failures; DockReopenTests unchanged — they assert the decision seam, not policy).
- (a) Fresh launch → window auto-opens (`count windows` = 1).
- (b) Close window → `count windows` = 0 AND `lsappinfo` ApplicationType stays **"Foreground"** (previously transitioned to "UIElement" — Dock icon now persists).
- (c) 3/3 consecutive `reopen` Apple-event cycles (Dock-click equivalent) reopened the window from the closed state.
- (d) `open -a Caddie` while running: instance count stays 1 (the second-instance LaunchServices artifact was specific to the removed `.accessory` state).
