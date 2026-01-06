//
//  FrameExporter.swift
//  AnonCam
//
//  Converts Metal textures to CVPixelBuffer for camera output
//

import CoreMedia
import CoreVideo
import Foundation
import Metal
import IOSurface

/// Manages CVPixelBuffer pool for efficient frame output
final class FrameExporter {

    // MARK: - Properties

    private var pixelBufferPool: CVPixelBufferPool?
    private var textureCache: CVMetalTextureCache?

    private(set) var width: Int
    private(set) var height: Int
    private let pixelFormat: OSType

    // MARK: - Initialization

    init(width: Int, height: Int, pixelFormat: OSType = kCVPixelFormatType_32BGRA, metalDevice: any MTLDevice) {
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat

        setupTextureCache(device: metalDevice)
        setupPixelBufferPool()
    }

    // MARK: - Setup

    private func setupTextureCache(device: any MTLDevice) {
        let result = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )

        if result != kCVReturnSuccess {
            print("FrameExporter: Failed to create texture cache: \(result)")
        }
    }

    private func setupPixelBufferPool() {
        let poolOptions: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64 // Align for performance
        ]

        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            nil,
            poolOptions as CFDictionary,
            &pixelBufferPool
        )

        if status != kCVReturnSuccess {
            print("FrameExporter: Failed to create pixel buffer pool: \(status)")
        }
    }

    // MARK: - Public API

    /// Create a new CVPixelBuffer from the pool
    func createPixelBuffer() -> CVPixelBuffer? {
        guard let pool = pixelBufferPool else {
            return nil
        }

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            pool,
            &pixelBuffer
        )

        if status != kCVReturnSuccess {
            print("FrameExporter: Failed to create pixel buffer: \(status)")
            return nil
        }

        return pixelBuffer
    }

    /// Convert Metal texture to CVPixelBuffer
    func makePixelBuffer(from texture: any MTLTexture, commandQueue: any MTLCommandQueue) -> CVPixelBuffer? {
        guard let pixelBuffer = createPixelBuffer() else {
            return nil
        }

        // Resize if dimensions don't match
        let textureWidth = texture.width
        let textureHeight = texture.height

        if textureWidth != width || textureHeight != height {
            updateSize(width: textureWidth, height: textureHeight)
            return makePixelBuffer(from: texture, commandQueue: commandQueue)
        }

        // Get or create Metal texture for the pixel buffer
        guard let cache = textureCache else {
            return nil
        }

        var cvTexture: CVMetalTexture?
        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            texture.pixelFormat,
            width,
            height,
            0,
            &cvTexture
        )

        guard result == kCVReturnSuccess,
              let cvTexture = cvTexture,
              let destinationTexture = CVMetalTextureGetTexture(cvTexture) else {
            print("FrameExporter: Failed to create texture from pixel buffer")
            return nil
        }

        // Blit source to destination
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            return nil
        }

        blitEncoder.copy(from: texture, to: destinationTexture)
        blitEncoder.endEncoding()

        // Synchronous copy for simplicity
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return pixelBuffer
    }

    /// Create CVPixelBuffer that shares storage with IOSurface (for IPC)
    func createPixelBufferWithIOSurface() -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?

        let iosurfaceProperties: [String: Any] = [
            kIOSurfaceIsGlobal as String: true
        ]

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: iosurfaceProperties
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )

        if status != kCVReturnSuccess {
            print("FrameExporter: Failed to create IOSurface-backed pixel buffer: \(status)")
            return nil
        }

        return pixelBuffer
    }

    /// Update the pool size (creates a new pool)
    func updateSize(width: Int, height: Int) {
        guard width != self.width || height != self.height else { return }

        self.width = width
        self.height = height
        setupPixelBufferPool()
    }

    // MARK: - Format Conversion

    /// Convert between pixel formats if needed
    static func convertPixelFormat(_ pixelBuffer: CVPixelBuffer, to format: OSType) -> CVPixelBuffer? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) != format else {
            return pixelBuffer
        }

        // For now, we only support BGRA output
        // Additional conversion would use vImage or Accelerate framework
        return pixelBuffer
    }

    /// Get the IOSurface from a pixel buffer (for IPC)
    static func getIOSurface(from pixelBuffer: CVPixelBuffer) -> IOSurface? {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer) else {
            return nil
        }
        return surface.takeUnretainedValue()
    }

    /// Create pixel buffer from IOSurface (for IPC receiver)
    static func createPixelBuffer(from ioSurface: IOSurface, pixelFormat: OSType) -> CVPixelBuffer? {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        let status = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            ioSurface,
            attributes as CFDictionary,
            &unmanagedPixelBuffer
        )

        guard status == kCVReturnSuccess,
              let pixelBuffer = unmanagedPixelBuffer?.takeRetainedValue() else {
            return nil
        }

        return pixelBuffer
    }
}

// MARK: - CMSampleBuffer helper

extension FrameExporter {

    /// Wrap a CVPixelBuffer in a CMSampleBuffer for CMIO Extension
    func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var formatDescription: CMFormatDescription?

        // Create format description
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )

        guard status == noErr, let formatDescription = formatDescription else {
            return nil
        }

        // Timing info
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime.invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: CMTime.invalid
        )

        // Create sample buffer
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )

        return sampleBuffer
    }
}
