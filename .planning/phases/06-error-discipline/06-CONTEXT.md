# Phase 6: Error Discipline - Context

**Gathered:** 2026-03-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Replace all silent error suppression: 14 try? instances → do-catch with logging, 4 force unwraps → guard-let, weak self closures → guard let self with logging, actor reentrancy fix in TranscriptionPipeline.

</domain>

<decisions>
## Implementation Decisions

### Claude's Discretion
All implementation choices are at Claude's discretion — mechanical error handling cleanup.

Key constraints:
- ERR-01: Every try? becomes do { try ... } catch { logger.warning/error(...) }
- ERR-02: Every .first! on directory access becomes guard let ... else { throw }
- ERR-03: Every weak self closure gets guard let self else { logger.warning(...); return }
- ERR-04: TranscriptionPipeline cannot execute two jobs concurrently
- Use os.Logger subsystem "com.caddie.app" consistently
- Pipeline now has onComplete callback and protocol-based DI

</decisions>

<code_context>
## Existing Code Insights

### Files with try? (from CONCERNS.md)
- TranscriptionPipeline.swift (lines 56, 112)
- AudioFileManager.swift (lines 224, 238-239, 245)
- SettingsView.swift (line 109)
- MeetingDetailView.swift (line 197)
- ExportSheet.swift (line 73)
- MeetingPatterns.swift (line 23)
- Logger.swift (line 19)

### Files with force unwraps
- Database.swift (line 12)
- AudioFileManager.swift (line 10)
- SettingsView.swift (line 102)
- MeetingListView.swift (line 64)

### Files with weak self issues
- MeetingDetector.swift (lines 46-49)
- CalendarMonitor.swift (lines 31-36, 53-55)
- AudioProcessMonitor.swift (line 17)
- AppState.swift (lines 74-79)

</code_context>

<specifics>
## Specific Ideas

No specific requirements beyond the 4 ERR requirements.

</specifics>

<deferred>
## Deferred Ideas

None.

</deferred>
