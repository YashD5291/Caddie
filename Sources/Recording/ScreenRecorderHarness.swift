#if DEBUG
import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import os

/// DEBUG-only headless entry points for driving `ScreenRecorder` from the command
/// line, reachable ONLY via launch arguments dispatched in `CaddieApp.init()` before
/// SwiftUI takes over. Two modes exist:
///
/// - `--screen-record-harness <path>` -> `runRecordMode`: records a display to a temp
///   `.mov` at the `.balanced` preset in a separate OS process, prints a machine-parseable
///   `HARNESS_READY pid=<pid> path=<path>` line once capture starts, then blocks the
///   main queue forever so the process stays alive until it is `kill -9`ed.
/// - `--validate-mov <path>` -> `runValidateMode`: loads the `.mov` via `AVURLAsset`,
///   reads `isPlayable` + `duration`, prints `VALIDATE isPlayable=<bool> duration=<secs>`,
///   and exits 0 (playable) / 2 (unplayable or load error).
///
/// This is the separate-process harness `Scripts/kill9-recovery-gate.sh` drives for the
/// VID-07 fragment-recovery gate: an XCTest process cannot cleanly `kill -9` itself and
/// still assert, so the crash-safety gate is shell-driven against this headless binary.
/// The production (non-DEBUG) launch path never sees this file.
enum ScreenRecorderHarness {

    private static let logger = Logger(subsystem: "com.caddie.app", category: "ScreenRecorderHarness")

    /// Retains the recorder for the process lifetime. Without this the recorder would
    /// deinit right after `start()` returns and finalize the file mid-capture.
    @MainActor private static var retainedRecorder: ScreenRecorder?

    /// Records `.display(nil)` at `.balanced` to `outputPath`, prints the ready line
    /// once capture is live, then blocks forever (until `kill -9`). Never returns.
    /// On start failure prints `HARNESS_ERROR` and exits 1.
    @MainActor
    static func runRecordMode(outputPath: String) -> Never {
        let url = URL(fileURLWithPath: outputPath)
        logger.info("Harness record mode -> \(outputPath, privacy: .public)")

        Task { @MainActor in
            // `recorder` is created here in a fresh (disconnected) region so it can be
            // passed to the nonisolated async `start`; it is attached to the MainActor
            // region only after `start` returns by storing it in `retainedRecorder`.
            let recorder = ScreenRecorder()
            // STOR-04 gate instrumentation: log the first-frame host-clock anchor
            // relative to the capture-start request so 18-04 can measure the offset.
            // Logged via os_log (not stdout) so it survives LaunchServices launches.
            var mutableTimebase = mach_timebase_info_data_t()
            mach_timebase_info(&mutableTimebase)
            let timebase = mutableTimebase
            let startTicks = mach_absolute_time()
            recorder.onFirstFrameHostTime = { anchorTicks in
                let deltaMs = (ScreenRecorder.hostTicksToSeconds(anchorTicks, timebase: timebase)
                    - ScreenRecorder.hostTicksToSeconds(startTicks, timebase: timebase)) * 1000
                Logger(subsystem: "com.caddie.app", category: "ScreenRecorderHarness")
                    .info("HARNESS_FIRST_FRAME anchor_ticks=\(anchorTicks, privacy: .public) start_to_anchor_ms=\(deltaMs, format: .fixed(precision: 1), privacy: .public)")
            }
            do {
                try await recorder.start(
                    target: .display(nil),
                    preset: .balanced,
                    outputURL: url
                )
                retainedRecorder = recorder
                print("HARNESS_READY pid=\(getpid()) path=\(outputPath)")
                fflush(stdout)
            } catch {
                print("HARNESS_ERROR \(error.localizedDescription)")
                fflush(stdout)
                exit(1)
            }
        }

        // Take over the main queue so the process stays alive recording until kill -9.
        // SwiftUI never starts because init() never returns.
        dispatchMain()
    }

    /// Loads `path` via `AVURLAsset`, prints playability + duration, and exits with a
    /// non-zero code when the file is not playable (so the gate script can assert).
    /// Never returns.
    static func runValidateMode(path: String) -> Never {
        let url = URL(fileURLWithPath: path)

        Task {
            let asset = AVURLAsset(url: url)
            do {
                let (isPlayable, duration) = try await asset.load(.isPlayable, .duration)
                let seconds = CMTimeGetSeconds(duration)
                print("VALIDATE isPlayable=\(isPlayable) duration=\(seconds)")
                fflush(stdout)
                exit(isPlayable ? 0 : 2)
            } catch {
                print("VALIDATE isPlayable=false duration=0.0 error=\(error.localizedDescription)")
                fflush(stdout)
                exit(2)
            }
        }

        dispatchMain()
    }
}
#endif
