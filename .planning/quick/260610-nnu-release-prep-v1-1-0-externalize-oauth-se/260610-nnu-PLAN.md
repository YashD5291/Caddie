---
phase: quick
plan: 260610-nnu
type: execute
wave: 1
depends_on: []
files_modified:
  - Sources/Calendar/GoogleOAuthSecrets.swift
  - Sources/Calendar/GoogleOAuthSecrets.swift.template
  - Sources/Calendar/GoogleOAuthConfig.swift
  - Sources/Models/ModelManager.swift
  - .gitignore
  - README.md
  - project.yml
autonomous: true
requirements: [RELEASE-1.1.0]

must_haves:
  truths:
    - "No Google OAuth client secret (the client-secret prefix) exists in any tracked or staged git file"
    - "App still compiles and authenticates locally using the gitignored secrets file"
    - "ModelManager throws instead of triggering a runtime HuggingFace download when sortformer models are missing"
    - "App version is 1.1.0 (build 2)"
    - "Working tree is clean after commits (only this plan's .planning artifacts remain)"
  artifacts:
    - path: "Sources/Calendar/GoogleOAuthSecrets.swift"
      provides: "Real clientID/clientSecret constants (gitignored, never committed)"
    - path: "Sources/Calendar/GoogleOAuthSecrets.swift.template"
      provides: "Committed placeholder template with setup instructions"
      contains: "GoogleOAuthSecrets"
    - path: "Sources/Calendar/GoogleOAuthConfig.swift"
      provides: "References GoogleOAuthSecrets constants, no literal secrets"
    - path: ".gitignore"
      contains: "GoogleOAuthSecrets.swift"
    - path: "Sources/Models/ModelManager.swift"
      provides: "Sortformer pre-check guard"
  key_links:
    - from: "Sources/Calendar/GoogleOAuthConfig.swift"
      to: "Sources/Calendar/GoogleOAuthSecrets.swift"
      via: "GoogleOAuthSecrets.clientID / .clientSecret references"
      pattern: "GoogleOAuthSecrets\\.(clientID|clientSecret)"
---

<objective>
Prepare Caddie v1.1.0 for a clean, secret-free PR to main: externalize the hardcoded Google OAuth client secret, harden the no-runtime-download guarantee for the sortformer diarization model, bump the version, and commit all branch work in logical atomic chunks.

Purpose: The remote is a PUBLIC GitHub repo (YashD5291/Caddie). A real OAuth secret currently sits in the uncommitted working tree (`Sources/Calendar/GoogleOAuthConfig.swift:9`). It must be removed from anything git can ever see BEFORE any commit touches that file. The app must also be fully bundled — no runtime model downloads — so it works offline as installed.

Output: Gitignored secrets file + committed template, version bump to 1.1.0/2, sortformer guard, and a clean committed tree ready for PR.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
</execution_context>

<context>
@.planning/STATE.md
@./CLAUDE.md

<interfaces>
Current GoogleOAuthConfig.swift (Sources/Calendar/GoogleOAuthConfig.swift) exposes:
```swift
enum GoogleOAuthConfig {
    static let clientID = "736932798207-9j5uipki4somq90inf7ich0dvei5dvul.apps.googleusercontent.com"
    static let clientSecret = "<REDACTED-CLIENT-SECRET>"   // SECRET — must move out
    static let callbackScheme: String = "com.googleusercontent.apps.736932798207-9j5uipki4somq90inf7ich0dvei5dvul"
    static let redirectURI = "\(callbackScheme):/oauth2redirect/google"
    static let scopes = "openid email https://www.googleapis.com/auth/calendar.readonly"
    static let authorizationURL = "https://accounts.google.com/o/oauth2/v2/auth"
    static let tokenURL = "https://oauth2.googleapis.com/token"
    static let revocationURL = "https://oauth2.googleapis.com/revoke"
    static let userinfoURL = "https://openidconnect.googleapis.com/v1/userinfo"
}
```
Note: `clientID` is embedded in `callbackScheme` (a desktop-app reversed client ID). The clientID is generally considered non-secret for installed apps, but the orchestrator directs moving BOTH clientID and clientSecret into the secrets file. Keep `callbackScheme`/`redirectURI` derivable; build them from `GoogleOAuthSecrets.clientID` so there is a single source of truth.

ModelManager.swift (Sources/Models/ModelManager.swift) — the ASR path already guards with:
```swift
guard AsrModels.modelsExist(at: asrDir, version: .v3) else {
    throw ModelLoadError.modelsNotFound("ASR models missing at \(asrDir.path)")
}
```
The sortformer path (~line 81) calls `SortformerModels.loadFromHuggingFace(config: .default, cacheDirectory: modelsDir)` with NO pre-check. `ModelLoadError.modelsNotFound(String)` already exists. Bundled sortformer path: `Resources/Models/sortformer/SortformerV2.mlmodelc` (confirmed present).

xcodegen sources include `Sources/**`, so a gitignored `GoogleOAuthSecrets.swift` in `Sources/Calendar/` still compiles locally.

README.md already has a "Google Calendar Setup (Optional)" section (~line 94) referencing `Sources/Calendar/GoogleOAuthConfig.swift` — update that note to the template-copy flow.
</interfaces>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Externalize OAuth secret + harden .gitignore (MUST be first)</name>
  <files>Sources/Calendar/GoogleOAuthSecrets.swift, Sources/Calendar/GoogleOAuthSecrets.swift.template, Sources/Calendar/GoogleOAuthConfig.swift, .gitignore, README.md</files>
  <action>
1. Create `Sources/Calendar/GoogleOAuthSecrets.swift` (this file WILL be gitignored) containing the REAL values currently in GoogleOAuthConfig.swift:
   ```swift
   import Foundation

   /// Real OAuth credentials. This file is gitignored — never commit it.
   /// Copy GoogleOAuthSecrets.swift.template to create your own from Google Cloud Console.
   enum GoogleOAuthSecrets {
       static let clientID = "736932798207-9j5uipki4somq90inf7ich0dvei5dvul.apps.googleusercontent.com"
       static let clientSecret = "<REDACTED-CLIENT-SECRET>"
   }
   ```

2. Create `Sources/Calendar/GoogleOAuthSecrets.swift.template` (this file IS committed) with placeholder values + a header comment explaining setup:
   ```swift
   import Foundation

   /// OAuth credentials template.
   /// SETUP: Copy this file to `GoogleOAuthSecrets.swift` (same directory) and fill in
   /// your own values from Google Cloud Console (APIs & Services → Credentials →
   /// OAuth 2.0 Client ID, Desktop application type). The real file is gitignored.
   enum GoogleOAuthSecrets {
       static let clientID = "YOUR_CLIENT_ID.apps.googleusercontent.com"
       static let clientSecret = "YOUR_CLIENT_SECRET"
   }
   ```

3. Edit `Sources/Calendar/GoogleOAuthConfig.swift` so it references `GoogleOAuthSecrets` instead of literals. Keep a single source of truth — derive callbackScheme from the clientID's leading numeric project id portion. Concretely:
   - `static let clientID = GoogleOAuthSecrets.clientID`
   - `static let clientSecret = GoogleOAuthSecrets.clientSecret`
   - Build `callbackScheme` by reversing the clientID: it is `com.googleusercontent.apps.` + the clientID with the `.apps.googleusercontent.com` suffix stripped. Implement as a computed/static derived from `GoogleOAuthSecrets.clientID` (e.g. drop the `.apps.googleusercontent.com` suffix, prefix with `com.googleusercontent.apps.`). Keep `redirectURI`, `scopes`, and all endpoint constants UNCHANGED.
   - Result: GoogleOAuthConfig.swift contains ZERO literal secret/clientID strings — only references to GoogleOAuthSecrets and the derived scheme logic.

4. Edit `.gitignore`: add two lines under a new `# Secrets` section:
   ```
   # Secrets
   Sources/Calendar/GoogleOAuthSecrets.swift

   # Python cache
   scripts/__pycache__/
   ```

5. Edit `README.md` "Google Calendar Setup (Optional)" section: change the step that says to replace the placeholder in `GoogleOAuthConfig.swift` to instead: "Copy `Sources/Calendar/GoogleOAuthSecrets.swift.template` to `Sources/Calendar/GoogleOAuthSecrets.swift` and fill in your client ID and secret from Google Cloud Console." Keep mention of updating the reversed client ID in `Resources/Info.plist` if that step exists.

6. Run `make test` (xcodegen regenerates project picking up Sources/**; the gitignored secrets file compiles locally).

7. CRITICAL pre-commit secret scan. Stage ONLY the four committed files, then verify zero secret leakage:
   ```
   git add Sources/Calendar/GoogleOAuthSecrets.swift.template Sources/Calendar/GoogleOAuthConfig.swift .gitignore README.md
   git check-ignore Sources/Calendar/GoogleOAuthSecrets.swift scripts/__pycache__/   # both must print (ignored)
   test "$(git diff --cached | grep -c "<secret-prefix>")" -eq 0   # MUST be 0
   git ls-files --error-unmatch Sources/Calendar/GoogleOAuthSecrets.swift 2>/dev/null && echo "LEAK: secret file tracked" && exit 1 || true
   ```
   If `git diff --cached | grep -c "<secret-prefix>"` is not 0, or the secrets file is tracked, STOP and fix before committing.

8. Commit: `git commit -m "chore(security): externalize Google OAuth credentials to gitignored file"` (NO Co-Authored-By line).
  </action>
  <verify>
    <automated>git check-ignore Sources/Calendar/GoogleOAuthSecrets.swift && [ "$(git diff HEAD~1 -- Sources/Calendar/GoogleOAuthConfig.swift README.md .gitignore Sources/Calendar/GoogleOAuthSecrets.swift.template | grep -c "<secret-prefix>")" -eq 0 ] && ! git ls-files --error-unmatch Sources/Calendar/GoogleOAuthSecrets.swift 2>/dev/null && make test</automated>
  </verify>
  <done>GoogleOAuthSecrets.swift is gitignored and untracked; template + updated GoogleOAuthConfig.swift + .gitignore + README committed; no secret-token string in any committed/staged content; make test passes.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: Sortformer no-runtime-download guard + version bump</name>
  <files>Sources/Models/ModelManager.swift, project.yml</files>
  <behavior>
    - When the sortformer model directory (`Models/sortformer/SortformerV2.mlmodelc`) is missing from the bundle, ModelManager surfaces `ModelLoadError.modelsNotFound` (sets `loadError`) instead of calling `SortformerModels.loadFromHuggingFace` — i.e. no network download is attempted.
    - When present, loading proceeds unchanged.
  </behavior>
  <action>
1. In `Sources/Models/ModelManager.swift`, before the `SortformerModels.loadFromHuggingFace(...)` call (~line 81), add a guard mirroring the ASR `modelsExist` pattern. Since FluidAudio has no `modelsExist` equivalent for sortformer, use a FileManager check on the known bundled path:
   ```swift
   let sortformerModelPath = modelsDir
       .appendingPathComponent("sortformer")
       .appendingPathComponent("SortformerV2.mlmodelc")
   guard FileManager.default.fileExists(atPath: sortformerModelPath.path) else {
       throw ModelLoadError.modelsNotFound("Sortformer models missing at \(sortformerModelPath.path)")
   }
   ```
   Add a brief comment explaining this prevents FluidAudio's runtime HuggingFace download in a read-only/offline app bundle (mirror the ASR guard's comment intent). Leave the existing `loadFromHuggingFace` call as-is — it only runs when the bundled models exist, where it loads from `cacheDirectory` without a network round-trip.

2. TDD where testable: ModelManager is `@MainActor @Observable` and `loadModelsFromBundle()` reads from `Bundle.main`, which is awkward to unit-test directly. Do NOT invent a fake bundle harness if it requires refactoring production code beyond the guard. If a clean test is feasible (e.g. extracting the path-check into a small testable static helper like `static func sortformerModelsExist(in modelsDir: URL) -> Bool` and asserting true/false against a temp dir with/without the file), add it as `Tests/ModelManagerTests.swift` with two cases. If extraction would be more than a trivial, side-effect-free helper, skip the test and note in the commit body that the guard is verified by the existing bundle build path.

3. Edit `project.yml`: `MARKETING_VERSION: "1.0.0"` → `"1.1.0"`, `CURRENT_PROJECT_VERSION: "1"` → `"2"`.

4. Run `make test`.

5. Commit: `git commit -m "feat(models): guard against runtime sortformer download; bump to 1.1.0"` (include ModelManager.swift, project.yml, and the test file if created). NO Co-Authored-By line.
  </action>
  <verify>
    <automated>grep -q 'MARKETING_VERSION: "1.1.0"' project.yml && grep -q 'CURRENT_PROJECT_VERSION: "2"' project.yml && grep -q "sortformer" Sources/Models/ModelManager.swift && grep -q "modelsNotFound" Sources/Models/ModelManager.swift && make test</automated>
  </verify>
  <done>ModelManager throws modelsNotFound when the bundled sortformer .mlmodelc is absent (no HuggingFace download path reachable when missing); project.yml at 1.1.0/2; make test passes; changes committed.</done>
</task>

<task type="auto">
  <name>Task 3: Commit remaining branch work in atomic chunks</name>
  <files>Makefile, Sources/Calendar/*, Sources/Recording/AudioDeviceManager.swift, Sources/Transcription/*, Sources/UI/**, Tests/*, project.yml (remaining hunks), scripts/*, Resources/CaddieDebug.entitlements, docs/superpowers/**</files>
  <action>
No code changes — pure git organization. Task 1 already removed the secret risk, so it is now safe to commit GoogleOAuthConfig.swift-adjacent calendar files. Inspect `git diff <file>` for each group to write accurate, specific commit messages (what + why). Suggested atomic commits (adjust grouping if the diffs warrant, but keep each logical and atomic). NO Co-Authored-By lines on any commit.

1. `feat(calendar): auth/error/event refinements`
   - Sources/Calendar/GoogleAuthError.swift, GoogleAuthManager.swift, GoogleCalendarEvent.swift, GoogleCalendarService.swift, GoogleOAuthConfig.swift (only if it still has uncommitted hunks after Task 1 — likely none), Tests/GoogleCalendarEventTests.swift, Tests/GoogleCalendarServiceTests.swift

2. `feat(transcription): ASR detokenization fix + pipeline mono handling`
   - Sources/Transcription/ASREngine.swift, Sources/Transcription/TranscriptionPipeline.swift, Tests/ASREngineTests.swift, and any related modified test (e.g. Tests covering these)

3. `feat(ui): main window, schedule, settings, onboarding updates`
   - Sources/UI/MainWindow/{ContentView,MeetingDetailView,MeetingListView,TodayScheduleView}.swift, Sources/UI/MainWindow/LoadingOverlay.swift (untracked), Sources/UI/Onboarding/OnboardingView.swift, Sources/UI/Settings/SettingsView.swift, Sources/Recording/AudioDeviceManager.swift, plus any modified coordinator/recording/notification files not otherwise grouped (RecordingCoordinator, RecordingState, AudioRecorder, MicrophoneCapture, SystemAudioCapture, NotificationManager, AppState, CaddieApp and their tests) — group these sensibly; if they form a distinct concern, make a separate `feat`/`fix` commit with an accurate message derived from the diff.

4. `build: debug entitlements, model script, build config`
   - Resources/CaddieDebug.entitlements (untracked, referenced by project.yml:25), scripts/download-models.sh, Makefile, any remaining project.yml hunks not part of the version bump

5. `chore(scripts): release pipeline + transcript fix utility`
   - scripts/build-dmg.sh, scripts/release.sh, scripts/fix-broken-transcripts.py (untracked)

6. `docs: google calendar integration spec + plan`
   - docs/superpowers/plans/2026-04-04-google-calendar-integration.md, docs/superpowers/specs/2026-04-04-google-calendar-integration-design.md

NEVER stage `scripts/__pycache__/` (now gitignored by Task 1). After all commits, confirm clean tree.
  </action>
  <verify>
    <automated>git ls-files --error-unmatch Resources/CaddieDebug.entitlements >/dev/null 2>&1 && [ -z "$(git status --short | grep -v '^.. .planning/' )" ] && ! git ls-files | grep -q '__pycache__' && make test</automated>
  </verify>
  <done>All branch work committed in logical atomic chunks with accurate messages; CaddieDebug.entitlements tracked; no __pycache__ tracked; `git status --short` shows only this plan's .planning artifacts; make test green on the fully committed tree.</done>
</task>

</tasks>

<verification>
- No secret-token secret anywhere in git: `git log -p | grep -c "<secret-prefix>"` returns 0, and `git diff --cached | grep -c "<secret-prefix>"` returns 0.
- `git check-ignore Sources/Calendar/GoogleOAuthSecrets.swift scripts/__pycache__/` both print (ignored).
- `grep -q 'MARKETING_VERSION: "1.1.0"' project.yml` succeeds.
- ModelManager.swift contains the sortformer existence guard throwing modelsNotFound.
- `git status --short` clean except .planning/ artifacts; `make test` passes.
</verification>

<success_criteria>
- The real OAuth secret lives only in the gitignored Sources/Calendar/GoogleOAuthSecrets.swift; a committed .template documents setup; GoogleOAuthConfig.swift compiles by referencing it.
- App refuses to attempt a runtime HuggingFace download for sortformer when bundled models are absent.
- Version is 1.1.0 (build 2).
- Entire branch is committed in clean atomic chunks, tree clean, tests green — ready to open a PR to main.
</success_criteria>

<output>
After completion, create `.planning/quick/260610-nnu-release-prep-v1-1-0-externalize-oauth-se/260610-nnu-SUMMARY.md`
</output>
