import XCTest
@testable import Caddie

final class SPSCRingBufferTests: XCTestCase {

    func testWriteAndRead() {
        let buffer = SPSCRingBuffer(capacity: 256)

        // Write 100 samples
        let samples = Array(0..<100).map { Int16($0) }
        let written = samples.withUnsafeBufferPointer { ptr in
            buffer.write(ptr, count: 100)
        }
        XCTAssertEqual(written, 100)
        XCTAssertEqual(buffer.availableToRead, 100)

        // Read them back
        let output = UnsafeMutablePointer<Int16>.allocate(capacity: 100)
        defer { output.deallocate() }
        let read = buffer.read(into: output, count: 100)
        XCTAssertEqual(read, 100)

        for i in 0..<100 {
            XCTAssertEqual(output[i], Int16(i), "Sample \(i) mismatch")
        }
    }

    func testFullBuffer() {
        let buffer = SPSCRingBuffer(capacity: 128)
        XCTAssertEqual(buffer.capacity, 128) // already power of 2

        // Fill to capacity
        let samples = Array(repeating: Int16(42), count: 128)
        let written = samples.withUnsafeBufferPointer { ptr in
            buffer.write(ptr, count: 128)
        }
        XCTAssertEqual(written, 128)
        XCTAssertEqual(buffer.availableToWrite, 0)
        XCTAssertEqual(buffer.availableToRead, 128)

        // Try to write more -- should fail
        let extra = [Int16(99)]
        let extraWritten = extra.withUnsafeBufferPointer { ptr in
            buffer.write(ptr, count: 1)
        }
        XCTAssertEqual(extraWritten, 0)
    }

    func testReadFromEmptyBuffer() {
        let buffer = SPSCRingBuffer(capacity: 64)
        XCTAssertEqual(buffer.availableToRead, 0)

        let output = UnsafeMutablePointer<Int16>.allocate(capacity: 10)
        defer { output.deallocate() }
        let read = buffer.read(into: output, count: 10)
        XCTAssertEqual(read, 0)
    }

    func testWrapAround() {
        let buffer = SPSCRingBuffer(capacity: 256)
        let cap = buffer.capacity // 256

        // Write 3/4 capacity
        let threeQuarter = cap * 3 / 4 // 192
        let batch1 = Array(0..<threeQuarter).map { Int16($0 % 1000) }
        let written1 = batch1.withUnsafeBufferPointer { ptr in
            buffer.write(ptr, count: threeQuarter)
        }
        XCTAssertEqual(written1, threeQuarter)

        // Read 3/4 capacity
        let output1 = UnsafeMutablePointer<Int16>.allocate(capacity: threeQuarter)
        defer { output1.deallocate() }
        let read1 = buffer.read(into: output1, count: threeQuarter)
        XCTAssertEqual(read1, threeQuarter)
        for i in 0..<threeQuarter {
            XCTAssertEqual(output1[i], Int16(i % 1000), "Batch 1 sample \(i) mismatch")
        }

        // Write another 3/4 capacity -- this wraps around the boundary
        let batch2 = Array(0..<threeQuarter).map { Int16((500 + $0) % 1000) }
        let written2 = batch2.withUnsafeBufferPointer { ptr in
            buffer.write(ptr, count: threeQuarter)
        }
        XCTAssertEqual(written2, threeQuarter)

        // Read those back
        let output2 = UnsafeMutablePointer<Int16>.allocate(capacity: threeQuarter)
        defer { output2.deallocate() }
        let read2 = buffer.read(into: output2, count: threeQuarter)
        XCTAssertEqual(read2, threeQuarter)
        for i in 0..<threeQuarter {
            XCTAssertEqual(output2[i], Int16((500 + i) % 1000), "Batch 2 sample \(i) mismatch")
        }
    }

    func testPartialRead() {
        let buffer = SPSCRingBuffer(capacity: 64)

        // Write 10 samples
        let samples = Array(repeating: Int16(7), count: 10)
        let written = samples.withUnsafeBufferPointer { ptr in
            buffer.write(ptr, count: 10)
        }
        XCTAssertEqual(written, 10)

        // Request 50 -- should only get 10
        let output = UnsafeMutablePointer<Int16>.allocate(capacity: 50)
        defer { output.deallocate() }
        let read = buffer.read(into: output, count: 50)
        XCTAssertEqual(read, 10)

        for i in 0..<10 {
            XCTAssertEqual(output[i], Int16(7))
        }
    }

    func testCapacityRoundsUpToPowerOf2() {
        let buffer1 = SPSCRingBuffer(capacity: 100)
        XCTAssertEqual(buffer1.capacity, 128)

        let buffer2 = SPSCRingBuffer(capacity: 129)
        XCTAssertEqual(buffer2.capacity, 256)

        let buffer3 = SPSCRingBuffer(capacity: 256)
        XCTAssertEqual(buffer3.capacity, 256)

        let buffer4 = SPSCRingBuffer(capacity: 1)
        XCTAssertEqual(buffer4.capacity, 1)
    }

    func testAvailableToReadAndWriteConsistency() {
        let buffer = SPSCRingBuffer(capacity: 64)
        let cap = buffer.capacity

        XCTAssertEqual(buffer.availableToRead + buffer.availableToWrite, cap)

        // Write some
        let samples = Array(repeating: Int16(1), count: 20)
        _ = samples.withUnsafeBufferPointer { ptr in
            buffer.write(ptr, count: 20)
        }
        XCTAssertEqual(buffer.availableToRead + buffer.availableToWrite, cap)

        // Read some
        let output = UnsafeMutablePointer<Int16>.allocate(capacity: 10)
        defer { output.deallocate() }
        _ = buffer.read(into: output, count: 10)
        XCTAssertEqual(buffer.availableToRead + buffer.availableToWrite, cap)

        // Fill the rest
        let fill = Array(repeating: Int16(2), count: buffer.availableToWrite)
        _ = fill.withUnsafeBufferPointer { ptr in
            buffer.write(ptr, count: fill.count)
        }
        XCTAssertEqual(buffer.availableToRead + buffer.availableToWrite, cap)
    }
}
