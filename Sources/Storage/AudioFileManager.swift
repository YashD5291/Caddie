import Foundation
import AudioToolbox

enum AudioFileManager {
    /// Base directory for all audio files.
    static var audioDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Caddie/audio", isDirectory: true)
        return appSupport
    }

    /// Ensures the audio directory exists.
    static func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: audioDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Returns the WAV file path for a given meeting ID.
    static func wavPath(for meetingId: String) -> URL {
        audioDirectory.appendingPathComponent("\(meetingId).wav")
    }

    /// Returns the ALAC (.m4a) file path for a given meeting ID.
    static func alacPath(for meetingId: String) -> URL {
        audioDirectory.appendingPathComponent("\(meetingId).m4a")
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

    /// Finds orphaned WAV files (WAV files in audio directory that were not cleaned up).
    static func findOrphanedWAVs() -> [URL] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return contents.filter { $0.pathExtension.lowercased() == "wav" }
    }

    /// Deletes both WAV and M4A files for a given meeting ID.
    static func deleteAudio(meetingId: String) {
        let fm = FileManager.default
        let wav = wavPath(for: meetingId)
        let m4a = alacPath(for: meetingId)
        try? fm.removeItem(at: wav)
        try? fm.removeItem(at: m4a)
    }

    /// Returns total bytes used by all files in the audio directory.
    static func totalStorageUsed() -> UInt64 {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else {
            return 0
        }
        return contents.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return total + UInt64(size)
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
