import Darwin

/// Lock-free single-producer, single-consumer ring buffer for Int16 audio samples.
///
/// Producer (real-time audio thread): calls `write()` -- no locks, no allocations, no ObjC dispatch.
/// Consumer (main thread flush timer): calls `read()` -- may allocate freely.
///
/// Thread safety is achieved through SPSC invariants:
/// - Only the producer writes `head`; only the consumer reads it.
/// - Only the consumer writes `tail`; only the producer reads it.
/// - `OSMemoryBarrier()` after index updates ensures cross-thread visibility.
///
/// Capacity is always a power of 2 so modulo is a fast bitwise AND.
final class SPSCRingBuffer {

    private let buffer: UnsafeMutablePointer<Int16>
    private let mask: Int
    let capacity: Int

    // head: written by producer, read by consumer
    // tail: written by consumer, read by producer
    private var head: Int = 0
    private var tail: Int = 0

    init(capacity requestedCapacity: Int) {
        let cap = SPSCRingBuffer.nextPowerOf2(requestedCapacity)
        self.capacity = cap
        self.mask = cap - 1
        self.buffer = .allocate(capacity: cap)
        self.buffer.initialize(repeating: 0, count: cap)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    // MARK: - Status

    var availableToRead: Int {
        OSMemoryBarrier()
        return head - tail
    }

    var availableToWrite: Int {
        return capacity - availableToRead
    }

    // MARK: - Producer (real-time thread)

    /// Write samples into the ring buffer. Returns the number of samples actually written.
    /// Safe to call from the real-time audio thread -- no locks, no allocations.
    @discardableResult
    func write(_ source: UnsafeBufferPointer<Int16>, count: Int) -> Int {
        let available = availableToWrite
        let toWrite = min(count, available)
        guard toWrite > 0 else { return 0 }

        let currentHead = head
        let startPos = currentHead & mask

        // Check if write wraps around the buffer boundary
        let contiguousSpace = capacity - startPos
        if toWrite <= contiguousSpace {
            // Single contiguous copy
            buffer.advanced(by: startPos)
                .update(from: source.baseAddress!, count: toWrite)
        } else {
            // Two-part copy: end of buffer, then beginning
            let firstPart = contiguousSpace
            let secondPart = toWrite - firstPart
            buffer.advanced(by: startPos)
                .update(from: source.baseAddress!, count: firstPart)
            buffer.update(from: source.baseAddress!.advanced(by: firstPart), count: secondPart)
        }

        head = currentHead + toWrite
        OSMemoryBarrier()

        return toWrite
    }

    // MARK: - Consumer (main thread)

    /// Read samples from the ring buffer. Returns the number of samples actually read.
    @discardableResult
    func read(into destination: UnsafeMutablePointer<Int16>, count: Int) -> Int {
        let available = availableToRead
        let toRead = min(count, available)
        guard toRead > 0 else { return 0 }

        let currentTail = tail
        let startPos = currentTail & mask

        // Check if read wraps around the buffer boundary
        let contiguousAvailable = capacity - startPos
        if toRead <= contiguousAvailable {
            // Single contiguous copy
            destination.update(from: buffer.advanced(by: startPos), count: toRead)
        } else {
            // Two-part copy: end of buffer, then beginning
            let firstPart = contiguousAvailable
            let secondPart = toRead - firstPart
            destination.update(from: buffer.advanced(by: startPos), count: firstPart)
            destination.advanced(by: firstPart).update(from: buffer, count: secondPart)
        }

        tail = currentTail + toRead
        OSMemoryBarrier()

        return toRead
    }

    // MARK: - Private

    private static func nextPowerOf2(_ n: Int) -> Int {
        guard n > 0 else { return 1 }
        if n & (n - 1) == 0 { return n } // already power of 2
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}
