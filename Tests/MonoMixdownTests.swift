import XCTest
import AudioToolbox
@testable import Caddie

final class MonoMixdownTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testMonoMixdown_averagesChannels() throws {
        let stereoURL = tempDir.appendingPathComponent("stereo.wav")
        try createStereoWAV(at: stereoURL, leftSamples: [1000, 3000], rightSamples: [2000, 4000])

        let monoURL = try AudioFileManager.createMonoMixdown(stereoURL: stereoURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: monoURL.path))

        let samples = try readMonoWAVSamples(from: monoURL)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0], 1500)
        XCTAssertEqual(samples[1], 3500)

        try? FileManager.default.removeItem(at: monoURL)
    }

    func testMonoMixdown_outputIsMono16kHz() throws {
        let stereoURL = tempDir.appendingPathComponent("stereo.wav")
        try createStereoWAV(at: stereoURL, leftSamples: [100, 200, 300], rightSamples: [100, 200, 300])

        let monoURL = try AudioFileManager.createMonoMixdown(stereoURL: stereoURL)

        var inputFile: ExtAudioFileRef?
        let status = ExtAudioFileOpenURL(monoURL as CFURL, &inputFile)
        XCTAssertEqual(status, noErr)
        guard let file = inputFile else { XCTFail("Could not open mono file"); return }
        defer { ExtAudioFileDispose(file) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format)

        XCTAssertEqual(format.mChannelsPerFrame, 1)
        XCTAssertEqual(format.mSampleRate, 16000.0)

        try? FileManager.default.removeItem(at: monoURL)
    }

    // MARK: - Helpers

    private func createStereoWAV(at url: URL, leftSamples: [Int16], rightSamples: [Int16]) throws {
        precondition(leftSamples.count == rightSamples.count)
        var format = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        var fileRef: ExtAudioFileRef?
        let status = ExtAudioFileCreateWithURL(
            url as CFURL, kAudioFileWAVEType, &format, nil,
            AudioFileFlags.eraseFile.rawValue, &fileRef
        )
        guard status == noErr, let file = fileRef else {
            throw NSError(domain: "test", code: Int(status))
        }
        defer { ExtAudioFileDispose(file) }

        var interleaved = [Int16]()
        for i in 0..<leftSamples.count {
            interleaved.append(leftSamples[i])
            interleaved.append(rightSamples[i])
        }

        try interleaved.withUnsafeBufferPointer { ptr in
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(interleaved.count * 2),
                    mData: UnsafeMutableRawPointer(mutating: ptr.baseAddress!)
                )
            )
            let writeStatus = ExtAudioFileWrite(file, UInt32(leftSamples.count), &bufferList)
            guard writeStatus == noErr else {
                throw NSError(domain: "test", code: Int(writeStatus))
            }
        }
    }

    private func readMonoWAVSamples(from url: URL) throws -> [Int16] {
        var fileRef: ExtAudioFileRef?
        let status = ExtAudioFileOpenURL(url as CFURL, &fileRef)
        guard status == noErr, let file = fileRef else {
            throw NSError(domain: "test", code: Int(status))
        }
        defer { ExtAudioFileDispose(file) }

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        ExtAudioFileGetProperty(file, kExtAudioFileProperty_FileDataFormat, &size, &format)

        let bufferSize = 8192
        let buffer = UnsafeMutablePointer<Int16>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        var samples = [Int16]()
        while true {
            var frameCount: UInt32 = UInt32(bufferSize)
            var bufferList = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(bufferSize * 2),
                    mData: buffer
                )
            )
            ExtAudioFileRead(file, &frameCount, &bufferList)
            if frameCount == 0 { break }
            for i in 0..<Int(frameCount) {
                samples.append(buffer[i])
            }
        }
        return samples
    }
}
