# Phase 1: Test Target Revival - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Fix the broken test target so tests compile, link, and execute. Update Swift version from 5.9 to 6.0+ for GRDB 7.10 compatibility and strict concurrency checking.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — pure infrastructure phase.

Key constraints from research:
- yyjson linker error caused by CLANG_ENABLE_CODE_COVERAGE on C targets (SR-14788)
- Fix via XcodeGen coverageTargets or CLANG_ENABLE_CODE_COVERAGE=NO fallback
- Swift version must go to 6.0+ for GRDB 7.10 compatibility
- Strict concurrency checking should be enabled

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- project.yml (XcodeGen spec) — build configuration lives here
- 10 existing test files in Tests/

### Established Patterns
- XcodeGen generates .xcodeproj from project.yml
- SPM for all dependencies
- Tests use XCTest framework

### Integration Points
- project.yml SWIFT_VERSION setting
- CaddieTests target in project.yml
- FluidAudio SPM dependency brings yyjson (C library)

</code_context>

<specifics>
## Specific Ideas

No specific requirements — infrastructure phase.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>
