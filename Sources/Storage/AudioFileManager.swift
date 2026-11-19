import Foundation
import AudioToolbox
import os

enum AudioFileManager {
    private static let logger = CaddieLogger.storage

    /// Base directory for all audio files.
    static var audioDirectory: URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            // applicationSupportDirectory is guaranteed by macOS; this is a catastrophic system failure
            fatalError("Application Support directory unavailable -- macOS system integrity compromised")
        }
        return appSupport.appendingPathComponent("Caddie/audio", isDirectory: true)
    }

    /// Ensures the audio directory exists.
    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Returns the WAV file path for a given meeting ID.
    static func wavPath(for meetingId: String, in directory: URL = audioDirectory) -> URL {
        directory.appendingPathComponent("\(meetingId).wav")
    }

    /// Returns the ALAC (.m4a) file path for a given meeting ID.
    static func alacPath(for meetingId: String, in directory: URL = audioDirectory) -> URL {
        directory.appendingPathComponent("\(meetingId).m4a")
    }

    /// Returns the video (.mov) file path for a given meeting ID.
    ///
    /// Canonical layout: the video sits beside the meeting's audio files so a single
    /// meeting id maps to exactly one `.mov`. `deleteMedia(meetingId:)` removes it together
    /// with the meeting, and the launch sweep `cleanupOrphanedVideos` removes any `.mov`
    /// left without a meeting row. `directory` exists so tests and the coordinator can
    /// target a temp directory.
    static func videoPath(for meetingId: String, in directory: URL = audioDirectory) -> URL {
        directory.appendingPathComponent("\(meetingId).mov")
    }

    /// Compresses a WAV file to ALAC (.m4a) using ExtAudioFile API.
    @discardableResult
    static func compressToALAC(wavURL: URL, outputURL: URL) throws -> URL {
        var inputFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(wavURL as CFURL, &inputFile)
        guard status == noErr, let input = inputFile else {
            throw AudioError.failedToOpenInput(status)
        }
        defer { ExtAudioFileDispose(input) }

        // Read input format
        var inputFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(
            input,
            kExtAudioFileProperty_FileDataFormat,
            &propertySize,
            &inputFormat
        )
        guard status == noErr else {
            throw AudioError.failedToReadFormat(status)
        }

        // Configure ALAC output format
        var outputFormat = AudioStreamBasicDescription(
            mSampleRate: inputFormat.mSampleRate,
            mFormatID: kAudioFormatAppleLossless,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 4096,
            mBytesPerFrame: 0,
            mChannelsPerFrame: inputFormat.mChannelsPerFrame,
            mBitsPerChannel: 0,
            mReserved: 0
        )

        var outputFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            outputURL as CFURL,
            kAudioFileM4AType,
            &outputFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &outputFile
        )
        guard status == noErr, let output = outputFile else {
            throw AudioError.failedToCreateOutput(status)
        }
        defer { ExtAudioFileDispose(output) }

        // Set client data format on output to match input (PCM)
        var clientFormat = inputFormat
        status = ExtAudioFileSetProperty(
            output,
            kExtAudioFileProperty_ClientDataFormat,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
            &clientFormat
        )
        guard status == noErr else {
            throw AudioError.failedToSetClientFormat(status)
        }

        // Read and write in chunks
        let bufferFrames: UInt32 = 4096
        let bufferSize = Int(bufferFrames * inputFormat.mBytesPerFrame)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            var frameCount = bufferFrames
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: inputFormat.mChannelsPerFrame,
                    mDataByteSize: UInt32(bufferSize),
                    mData: buffer
                )
            )

            status = ExtAudioFileRead(input, &frameCount, &bufferList)
            guard status == noErr else {
                throw AudioError.failedToRead(status)
            }

            if frameCount == 0 { break }

            status = ExtAudioFileWrite(output, frameCount, &bufferList)
            guard status == noErr else {
                throw AudioError.failedToWrite(status)
            }
        }

        return outputURL
    }

    /// Creates a mono mixdown from a stereo WAV file.
    /// Averages left and right channels: mono[i] = (left[i] + right[i]) / 2
    /// Returns the URL of the temp mono WAV file. Caller must delete it when done.
    static func createMonoMixdown(stereoURL: URL) throws -> URL {
        var inputFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(stereoURL as CFURL, &inputFile)
        guard status == noErr, let input = inputFile else {
            throw AudioError.failedToOpenInput(status)
        }
        defer { ExtAudioFileDispose(input) }

        var inputFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(input, kExtAudioFileProperty_FileDataFormat, &propertySize, &inputFormat)
        guard status == noErr else {
            throw AudioError.failedToReadFormat(status)
        }

        let sampleRate = inputFormat.mSampleRate
        let channelCount = inputFormat.mChannelsPerFrame
        guard channelCount == 2 else {
            return stereoURL
        }

        let monoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("caddie_mono_\(UUID().uuidString).wav")

        var monoFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var outputFile: ExtAudioFileRef?
        status = ExtAudioFileCreateWithURL(
            monoURL as CFURL, kAudioFileWAVEType, &monoFormat, nil,
            AudioFileFlags.eraseFile.rawValue, &outputFile
        )
        guard status == noErr, let output = outputFile else {
            throw AudioError.failedToCreateOutput(status)
        }
        defer { ExtAudioFileDispose(output) }

        let chunkFrames: UInt32 = 4096
        let stereoBufferSize = Int(chunkFrames * 2)
        let stereoBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: stereoBufferSize)
        defer { stereoBuffer.deallocate() }

        let monoBuffer = UnsafeMutablePointer<Int16>.allocate(capacity: Int(chunkFrames))
        defer { monoBuffer.deallocate() }

        while true {
            var frameCount = chunkFrames
            var readList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(stereoBufferSize * MemoryLayout<Int16>.size),
                    mData: stereoBuffer
                )
            )

            status = ExtAudioFileRead(input, &frameCount, &readList)
            guard status == noErr else { throw AudioError.failedToRead(status) }
            if frameCount == 0 { break }

            for i in 0..<Int(frameCount) {
                let left = Int32(stereoBuffer[i * 2])
                let right = Int32(stereoBuffer[i * 2 + 1])
                monoBuffer[i] = Int16((left + right) / 2)
            }

            var writeList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(Int(frameCount) * MemoryLayout<Int16>.size),
                    mData: monoBuffer
                )
            )

            status = ExtAudioFileWrite(output, frameCount, &writeList)
            guard status == noErr else { throw AudioError.failedToWrite(status) }
        }

        return monoURL
    }

    /// Finds orphaned WAV files (WAV files in audio directory that were not cleaned up).
    static func findOrphanedWAVs() -> [URL] {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: nil)
        } catch {
            logger.warning("Failed to enumerate audio directory: \(error.localizedDescription)")
            return []
        }
        return contents.filter { $0.pathExtension.lowercased() == "wav" }
    }

    // MARK: - Media Deletion

    /// Deletes every media file (`.wav`, `.m4a`, `.mov`) for a meeting, by meeting id.
    ///
    /// Deletion is keyed on the id, not on the `video_file` column: Phase-19-era and
    /// unverified videos have NULL there, so column-driven deletion would leak screen
    /// recordings. A missing file is expected (the WAV is removed after ALAC conversion,
    /// and audio-only meetings have no `.mov`), so it is never logged as a failure.
    static func deleteMedia(meetingId: String, in directory: URL = audioDirectory) {
        guard isSafeMeetingId(meetingId) else {
            logger.error("Refusing to delete media for unsafe meeting id")
            return
        }
        let mediaFiles = [
            wavPath(for: meetingId, in: directory),
            alacPath(for: meetingId, in: directory),
            videoPath(for: meetingId, in: directory),
        ]
        for url in mediaFiles {
            removeFileIfPresent(at: url)
        }
    }

    /// Removes a file, treating "no such file" as the expected outcome rather than a failure.
    static func removeFileIfPresent(at url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            logger.debug("No \(url.lastPathComponent) to delete")
        } catch {
            logger.warning("Failed to delete \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Rejects ids that could build a path outside the media directory.
    private static func isSafeMeetingId(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("..")
    }

    /// Returns total bytes used by all files in the audio directory.
    static func totalStorageUsed() -> UInt64 {
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: audioDirectory, includingPropertiesForKeys: [.fileSizeKey])
        } catch {
            logger.warning("Failed to enumerate audio directory for storage calculation: \(error.localizedDescription)")
            return 0
        }
        return contents.reduce(0) { total, url in
            let size: Int = {
                do {
                    return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                } catch {
                    logger.warning("Failed to read file size for \(url.lastPathComponent): \(error.localizedDescription)")
                    return 0
                }
            }()
            return total + UInt64(size)
        }
    }

    /// Removes orphaned caddie_mono_* temp files from previous sessions.
    /// Called on app startup to reclaim disk space from crashed transcriptions.
    static func cleanupOrphanedTempFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let fm = FileManager.default
        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        } catch {
            logger.warning("Failed to enumerate temp directory: \(error.localizedDescription)")
            return
        }

        let orphans = contents.filter { $0.lastPathComponent.hasPrefix("caddie_mono_") }
        for orphan in orphans {
            do {
                try fm.removeItem(at: orphan)
            } catch {
                logger.warning("Failed to remove orphaned temp file \(orphan.lastPathComponent): \(error.localizedDescription)")
            }
        }

        if !orphans.isEmpty {
            logger.info("Cleaned up \(orphans.count) orphaned temp file(s)")
        }
    }

    /// Deletes `.mov` files in `directory` whose meeting id has no row and no audio.
    ///
    /// Lists the files first and reads the ids second. `RecordingCoordinator` inserts the
    /// meeting row before it starts audio or video, so every `.mov` that exists at listing
    /// time already has its row and a later id read always contains it. Reading ids first
    /// could delete the video of a recording that started in between.
    ///
    /// Skips the sweep entirely when the ids cannot be read (a failed read is not "no
    /// meetings") and when the id set is empty while videos exist (a lost or recreated
    /// database must never wipe every video). Must run before any recording can start.
    ///
    /// A row-less `.mov` is deleted only when it also has no sibling `.m4a` or `.wav`. A
    /// real orphan never has audio: older versions deleted a meeting's audio and left its
    /// video. A lost, recreated, or stale-restored database leaves the audio in place, so
    /// that video is kept (D-14).
    static func cleanupOrphanedVideos(in directory: URL = audioDirectory, knownMeetingIds: () throws -> Set<String>) {
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        } catch {
            logger.warning("Skipping orphan video cleanup — cannot list \(directory.lastPathComponent): \(error.localizedDescription)")
            return
        }

        let videos = contents.filter(isRegularMovFile)
        guard !videos.isEmpty else { return }

        let ids: Set<String>
        do {
            ids = try knownMeetingIds()
        } catch {
            logger.error("Skipping orphan video cleanup — could not read meetings: \(error.localizedDescription)")
            return
        }

        guard !ids.isEmpty else {
            logger.warning("Skipping orphan video cleanup — the meetings table is empty but \(videos.count) video file(s) exist; refusing to treat every video as an orphan")
            return
        }

        let listedNames = Set(contents.map(\.lastPathComponent))
        var removedCount = 0
        for video in videos {
            let stem = video.deletingPathExtension().lastPathComponent
            guard !ids.contains(stem) else { continue }
            guard !hasSiblingAudio(stem: stem, in: directory, listedNames: listedNames) else {
                logger.warning("Keeping row-less video \(video.lastPathComponent): its audio still exists, so the database may be stale")
                continue
            }
            logger.info("Removing orphaned video \(video.lastPathComponent)")
            removeFileIfPresent(at: video)
            removedCount += 1
        }

        if removedCount > 0 {
            logger.info("Cleaned up \(removedCount) orphaned video file(s)")
        }
    }

    /// True when the meeting's `.m4a` or `.wav` is among the names listed from `directory`.
    private static func hasSiblingAudio(stem: String, in directory: URL, listedNames: Set<String>) -> Bool {
        [alacPath(for: stem, in: directory), wavPath(for: stem, in: directory)].contains { url in
            listedNames.contains(url.lastPathComponent)
        }
    }

    /// True for a regular file with a `.mov` extension (any case). A file whose type
    /// cannot be read is excluded: never delete what could not be classified.
    private static func isRegularMovFile(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "mov" else { return false }
        do {
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        } catch {
            logger.warning("Skipping \(url.lastPathComponent) in orphan video cleanup — cannot read file type: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Errors

    enum AudioError: Error {
        case failedToOpenInput(OSStatus)
        case failedToReadFormat(OSStatus)
        case failedToCreateOutput(OSStatus)
        case failedToSetClientFormat(OSStatus)
        case failedToRead(OSStatus)
        case failedToWrite(OSStatus)
    }
}
