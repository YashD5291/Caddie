# Phase 7: Precondition Guards - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Add disk space check before recording (block if <500MB) and model download timeout (5 min) with retry option during onboarding.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — precondition checks.

Key constraints:
- ERR-05: Check volumeAvailableCapacityForImportantUsage before recording, show alert if <500MB
- ERR-06: Model download wrapped in withTimeout (5 min), show error + retry option in onboarding
- Both failures must be recoverable by user (free space / retry download)
- RecordingCoordinator.executeStartRecording() is the place for disk check
- ModelManager.downloadModelsIfNeeded() is the place for timeout

</decisions>

<code_context>
## Existing Code Insights

### Reusable Assets
- RecordingCoordinator.swift — executeStartRecording()
- ModelManager.swift — downloadModelsIfNeeded()
- OnboardingView.swift — model download UI
- AppState.swift — thin wrapper

### Integration Points
- RecordingCoordinator before starting recording
- OnboardingView model download step

</code_context>

<specifics>
## Specific Ideas

No specific requirements beyond ERR-05 and ERR-06.

</specifics>

<deferred>
## Deferred Ideas

None.

</deferred>
