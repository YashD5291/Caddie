# Phase 14: Google Authentication - Validation

**Generated from:** 14-RESEARCH.md Validation Architecture section
**Date:** 2026-03-24

## Test Framework

| Property | Value |
|----------|-------|
| Framework | XCTest (built into Xcode 26.2) |
| Config file | project.yml (CaddieTests target) |
| Quick run command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -destination 'platform=macOS' -only-testing:CaddieTests` |
| Full suite command | `xcodebuild test -project Caddie.xcodeproj -scheme Caddie -destination 'platform=macOS'` |

## Phase Requirements to Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| AUTH-01 | PKCE code_verifier/challenge generation produces valid Base64URL strings of correct length | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testPKCEGeneration` | Wave 0 |
| AUTH-01 | Authorization URL contains all required query parameters | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testAuthURLConstruction` | Wave 0 |
| AUTH-01 | Token exchange decodes valid Google response into TokenResponse | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testTokenResponseDecoding` | Wave 0 |
| AUTH-02 | KeychainHelper save/load/delete round-trips data correctly | unit | `-only-testing:CaddieTests/KeychainHelperTests/testSaveLoadDelete` | Wave 0 |
| AUTH-02 | KeychainHelper handles errSecItemNotFound gracefully (returns nil) | unit | `-only-testing:CaddieTests/KeychainHelperTests/testLoadMissing` | Wave 0 |
| AUTH-02 | KeychainHelper save overwrites existing item | unit | `-only-testing:CaddieTests/KeychainHelperTests/testSaveOverwrite` | Wave 0 |
| AUTH-03 | Concurrent validAccessToken() calls produce exactly one refresh request | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testSerializedRefresh` | Wave 0 |
| AUTH-03 | Proactive refresh triggers 5 min before expiry | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testProactiveRefresh` | Wave 0 |
| AUTH-03 | Refresh failure with invalid_grant transitions to signedOut | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testRefreshFailure` | Wave 0 |
| AUTH-04 | Sign-out clears all Keychain items | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testSignOutClearsKeychain` | Wave 0 |
| AUTH-04 | Sign-out transitions state to signedOut | unit | `-only-testing:CaddieTests/GoogleAuthManagerTests/testSignOutState` | Wave 0 |
| AUTH-01 | Full browser sign-in flow with real Google account | manual-only | N/A -- requires browser interaction + Google account | N/A |
| AUTH-04 | Re-authentication after sign-out works | manual-only | N/A -- requires browser interaction | N/A |

## Sampling Rate

- **Per task commit:** Quick run of new test file only
- **Per wave merge:** Full suite (when build issue resolved)
- **Phase gate:** All AUTH test cases green before `/gsd:verify-work`

## Wave 0 Gaps

- [ ] `Tests/KeychainHelperTests.swift` -- covers AUTH-02 (Keychain CRUD)
- [ ] `Tests/GoogleAuthManagerTests.swift` -- covers AUTH-01, AUTH-03, AUTH-04 (PKCE, serialized refresh, sign-out)

Note: The ASWebAuthenticationSession browser flow itself (AUTH-01 full flow) is manual-only -- it requires real browser interaction with Google's consent screen. Unit tests cover everything up to and after the browser step (URL construction, token decoding, token refresh, Keychain operations).
