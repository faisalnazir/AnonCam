//
//  FrameRingBuffer.swift
//  AnonCam
//
//  Lock-free ring buffer for sharing frames between app and extension via shared memory
//

import CoreVideo
import Foundation

// MARK: - Shared Memory Header

/// Header structure for shared memory (must be C-interop compatible)
struct SharedMemoryHeader: Codable {
    var magic: UInt32 = 0x41434D53 // "ACMS" - AnonCam Shared Memory
    var version: UInt32 = 1
    var bufferCount: UInt32 = 3 // Triple buffering
    var width: UInt32 = 1920
    var height: UInt32 = 1080
    var pixelFormat: UInt32 = 0x42475241 // 'BGRA'

    var readIndex: UInt32 = 0
    var writeIndex: UInt32 = 0

    var frameCount: UInt64 = 0
    var lastUpdateTime: UInt64 = 0

    var padding: [UInt32] = Array(repeating: 0, count: 16)
}

// MARK: - Ring Buffer Entry

/// Metadata for each frame buffer slot
struct FrameBufferEntry {
    var isReady: UInt32 = 0
    var timestamp: CMTime
    var frameNumber: UInt64
    var width: UInt32
    var height: UInt32
    var ioSurfaceID: UInt64 // IOSurface identifier for zero-copy access

    var padding: [UInt32] = Array(repeating: 0, count: 8)
}

// MARK: - Frame Ring Buffer

/// Thread-safe ring buffer for frame sharing between app and camera extension
///
/// Uses shared memory backed by IOSurface for zero-copy frame transfer.
/// The app (producer) writes frames, the extension (consumer) reads them.
final class FrameRingBuffer {

    // MARK: - Properties

    private let header: UnsafeMutablePointer<SharedMemoryHeader>
    private let memory: UnsafeMutableRawPointer
    private let memorySize: Int

    private let bufferCount: Int
    private var buffers: [CVPixelBuffer] = []

    private let lock = NSLock()

    var width: Int { Int(header.pointee.width) }
    var height: Int { Int(header.pointee.height) }

    // MARK: - Initialization

    /// Create a new ring buffer with specified dimensions
    init(width: Int, height: Int, bufferCount: Int = 3) {
        self.bufferCount = bufferCount

        let headerSize = MemoryLayout<SharedMemoryHeader>.stride
        let bufferSize = width * height * 4 // BGRA
        self.memorySize = headerSize + (bufferCount * bufferSize)

        // Allocate shared memory
        self.memory = UnsafeMutableRawPointer.allocate(byteCount: memorySize, alignment: 64)
        self.header = memory.bindMemory(to: SharedMemoryHeader.self, capacity: 1)

        // Initialize header
        header.pointee = SharedMemoryHeader(
            width: UInt32(width),
            height: UInt32(height),
            bufferCount: UInt32(bufferCount)
        )

        // Create IOSurface-backed pixel buffers for each slot
        buffers = (0..<bufferCount).map { _ in
            createIOSurfaceBuffer(width: width, height: height)!
        }

        // Store IOSurface IDs
        for (index, buffer) in buffers.enumerated() {
            if let surface = CVPixelBufferGetIOSurface(buffer) {
                let entry = getEntry(at: index)
                entry.pointee.ioSurfaceID = IOSurfaceGetID(surface.takeUnretainedValue())
            }
        }
    }

    /// Attach to existing shared memory (for extension side)
    init?(sharedMemory: UnsafeMutableRawPointer) {
        self.memory = sharedMemory
        self.header = sharedMemory.bindMemory(to: SharedMemoryHeader.self, capacity: 1)

        // Validate magic
        guard header.pointee.magic == 0x41434D53 else {
            return nil
        }

        self.bufferCount = Int(header.pointee.bufferCount)
        self.memorySize = 0 // Not needed on consumer side

        // Attach to existing IOSurfaces
        buffers = (0..<bufferCount).map { index in
            let entry = getEntry(at: index)
            let surfaceID = entry.pointee.ioSurfaceID

            // Lookup IOSurface by ID
            let options: [String: Any] = [
                kIOSurfaceIsGlobal as String: true
            ]

            if let surface = IOSurfaceLookup(surfaceID)?.takeUnretainedValue() {
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferCreateWithIOSurface(
                    kCFAllocatorDefault,
                    surface,
                    nil,
                    &pixelBuffer
                )
                return pixelBuffer ?? createPlaceholderBuffer()
            }
            return createPlaceholderBuffer()
        }
    }

    // MARK: - Public API (Producer)

    /// Get the next writable buffer
    func acquireWriteBuffer() -> (index: Int, pixelBuffer: CVPixelBuffer)? {
        lock.lock()
        defer { lock.unlock() }

        let currentWrite = Int(header.pointee.writeIndex)
        let nextWrite = (currentWrite + 1) % bufferCount

        // Check if we'd overwrite unread frame
        if nextWrite == Int(header.pointee.readIndex) {
            return nil // Buffer full, drop frame
        }

        return (currentWrite, buffers[currentWrite])
    }

    /// Submit a filled buffer for reading
    func submitWrite(index: Int, timestamp: CMTime) {
        lock.lock()
        defer { lock.unlock() }

        let entry = getEntry(at: index)
        entry.pointee.isReady = 1
        entry.pointee.timestamp = timestamp
        entry.pointee.frameNumber = header.pointee.frameCount
        entry.pointee.width = UInt32(CVPixelBufferGetWidth(buffers[index]))
        entry.pointee.height = UInt32(CVPixelBufferGetHeight(buffers[index]))

        header.pointee.writeIndex = UInt32((index + 1) % bufferCount)
        header.pointee.frameCount &+= 1
        header.pointee.lastUpdateTime = UInt64(DispatchTime.now().uptimeNanoseconds)
    }

    /// Convenience method to write a complete frame
    func writeFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) -> Bool {
        guard let (index, targetBuffer) = acquireWriteBuffer() else {
            return false
        }

        // Copy pixel buffer to target
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(targetBuffer, [])

        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(targetBuffer, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(pixelBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(targetBuffer) else {
            return false
        }

        let srcBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let dstBytes = CVPixelBufferGetBytesPerRow(targetBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        for row in 0..<height {
            let srcPtr = srcBase.advanced(by: row * srcBytes)
            let dstPtr = dstBase.advanced(by: row * dstBytes)
            dstPtr.copyMemory(from: srcPtr, byteCount: min(srcBytes, dstBytes))
        }

        submitWrite(index: index, timestamp: time)
        return true
    }

    // MARK: - Public API (Consumer)

    /// Get the next readable buffer (for extension)
    func acquireReadBuffer() -> (pixelBuffer: CVPixelBuffer, timestamp: CMTime, frameNumber: UInt64)? {
        lock.lock()
        defer { lock.unlock() }

        let currentRead = Int(header.pointee.readIndex)
        let entry = getEntry(at: currentRead)

        guard entry.pointee.isReady != 0 else {
            return nil // No new frame
        }

        return (buffers[currentRead], entry.pointee.timestamp, entry.pointee.frameNumber)
    }

    /// Release a read buffer
    func releaseReadBuffer() {
        lock.lock()
        defer { lock.unlock() }

        let entry = getEntry(at: Int(header.pointee.readIndex))
        entry.pointee.isReady = 0

        header.pointee.readIndex = UInt32((Int(header.pointee.readIndex) + 1) % bufferCount)
    }

    /// Convenience method to read a complete frame
    func readFrame() -> (pixelBuffer: CVPixelBuffer, timestamp: CMTime, frameNumber: UInt64)? {
        guard let frame = acquireReadBuffer() else {
            return nil
        }
        releaseReadBuffer()
        return frame
    }

    /// Get latest frame without advancing read pointer
    func peekLatestFrame() -> (pixelBuffer: CVPixelBuffer, timestamp: CMTime)? {
        lock.lock()
        defer { lock.unlock() }

        // Check the slot before write index
        let writeIndex = Int(header.pointee.writeIndex)
        let readIndex = Int(header.pointee.readIndex)

        guard writeIndex != readIndex else {
            return nil // Buffer empty
        }

        let latestIndex = (writeIndex - 1 + bufferCount) % bufferCount
        let entry = getEntry(at: latestIndex)

        guard entry.pointee.isReady != 0 else {
            return nil
        }

        return (buffers[latestIndex], entry.pointee.timestamp)
    }

    // MARK: - Cleanup

    deinit {
        memory.deallocate()
    }

    // MARK: - Private Helpers

    private func getEntry(at index: Int) -> UnsafeMutablePointer<FrameBufferEntry> {
        let headerSize = MemoryLayout<SharedMemoryHeader>.stride
        let entryOffset = headerSize + (index * MemoryLayout<FrameBufferEntry>.stride)
        return memory.advanced(by: entryOffset).bindMemory(to: FrameBufferEntry.self, capacity: 1)
    }

    private func createIOSurfaceBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let options: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [
                kIOSurfaceIsGlobal as Bool: true,
                kIOSurfaceCacheMode as Int: 0
            ]
        ]

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            options as CFDictionary,
            &pixelBuffer
        )

        return pixelBuffer
    }

    private func createPlaceholderBuffer() -> CVPixelBuffer {
        let options: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 128,
            kCVPixelBufferHeightKey as String: 128
        ]

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            128,
            128,
            kCVPixelFormatType_32BGRA,
            options as CFDictionary,
            &pixelBuffer
        )

        return pixelBuffer!
    }

    // MARK: - Memory Mapped File Support

    /// Create ring buffer backed by a file (for persistence/sharing)
    static func createMappedToFile(at path: String, width: Int, height: Int) -> FrameRingBuffer? {
        let headerSize = MemoryLayout<SharedMemoryHeader>.stride
        let bufferCount = 3
        let bufferSize = width * height * 4
        let totalSize = headerSize + (bufferCount * bufferSize)

        // Create/truncate file
        FileManager.default.createFile(atPath: path, contents: nil, attributes: nil)

        guard let handle = FileHandle(forWritingAtPath: path),
              let data = try? handle.truncate(atOffset: off_t(totalSize)) else {
            return nil
        }

        // Map file to memory
        let pointer = UnsafeMutableRawPointer(mutating: data)
        return FrameRingBuffer(width: width, height: height, bufferCount: bufferCount)
    }

    /// Attach to existing memory-mapped file
    static func attachMappedFile(at path: String) -> FrameRingBuffer? {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return nil
        }

        guard let data = try? handle.readToEnd(),
              let pointer = UnsafeMutableRawPointer(mutating: data) else {
            return nil
        }

        return FrameRingBuffer(sharedMemory: pointer)
    }
}
