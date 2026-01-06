//
//  ExtensionStream.swift
//  AnonCamCameraExtension
//
//  CoreMediaIO Extension Stream Source - outputs video frames
//

import CoreMediaIO
import CoreVideo
import Foundation

/// The stream source handles actual frame output
/// It receives frames from the app via IPC and delivers them to the client
class ExtensionStreamSource: NSObject {

    // MARK: - Properties

    private(set) weak var deviceSource: ExtensionDeviceSource!

    private var _stream: CMIOExtensionStream?
    var stream: CMIOExtensionStream? {
        get { _stream }
        set { _stream = newValue }
    }

    // MARK: - Format Description

    private var formatDescriptions: [CMFormatDescription] = []

    var supportedFormats: [CMVideoFormatDescription] {
        formatDescriptions.compactMap { $0 as? CMVideoFormatDescription }
    }

    // MARK: - Frame Queue

    private let frameQueueLock = NSLock()
    private var pendingFrames: [QueuedFrame] = []
    private let maxPendingFrames = 3

    private struct QueuedFrame {
        let pixelBuffer: CVPixelBuffer
        let timestamp: CMTime
    }

    // MARK: - Timer for frame delivery

    private var frameTimer: DispatchSourceTimer?
    private let frameQueueDispatch = DispatchQueue(label: "com.anoncam.stream.timer")

    // MARK: - Settings

    private(set) var activeFormatIndex: Int = 0

    // MARK: - Initialization

    init(deviceSource: ExtensionDeviceSource) {
        self.deviceSource = deviceSource
        super.init()
        setupFormats()
    }

    private func setupFormats() {
        // Define supported formats for the virtual camera
        let formats: [(width: Int, height: Int, frameRate: Float)] = [
            (1920, 1080, 30),
            (1920, 1080, 60),
            (1280, 720, 30),
            (1280, 720, 60),
            (640, 480, 30)
        ]

        for format in formats {
            let dims = CMVideoDimensions(width: Int32(format.width), height: Int32(format.height))

            var formatDescription: CMFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                kCFAllocatorDefault,
                kCVPixelFormatType_32BGRA,
                dims.width,
                dims.height,
                nil,
                &formatDescription
            )

            if status == noErr, let desc = formatDescription {
                formatDescriptions.append(desc)
            }
        }
    }

    // MARK: - Streaming Control

    func startStreaming() {
        guard frameTimer == nil else { return }

        frameTimer = DispatchSource.makeTimerSource(queue: frameQueueDispatch)
        frameTimer?.setEventHandler { [weak self] in
            self?.sendNextFrame()
        }
        frameTimer?.schedule(deadline: .now(), repeating: .milliseconds(33)) // ~30 FPS
        frameTimer?.resume()
    }

    func stopStreaming() {
        frameTimer?.cancel()
        frameTimer = nil

        frameQueueLock.lock()
        pendingFrames.removeAll()
        frameQueueLock.unlock()
    }

    // MARK: - Frame Queue (from device)

    func queueFrame(_ pixelBuffer: CVPixelBuffer, at timestamp: CMTime) {
        frameQueueLock.lock()

        // Drop old frames if queue is full
        while pendingFrames.count >= maxPendingFrames {
            pendingFrames.removeFirst()
        }

        pendingFrames.append(QueuedFrame(pixelBuffer: pixelBuffer, timestamp: timestamp))
        frameQueueLock.unlock()
    }

    // MARK: - Frame Output (timer callback)

    private func sendNextFrame() {
        guard let stream = stream else { return }

        frameQueueLock.lock()
        let frame = pendingFrames.first
        frameQueueLock.unlock()

        guard let frame = frame else {
            return
        }

        // Create CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: frame.timestamp,
            decodeTimeStamp: CMTime.invalid
        )

        guard let formatDesc = formatDescriptions[activeFormatIndex] as? CMFormatDescription else {
            return
        }

        let status = CMSampleBufferCreateReadyWithImageBuffer(
            kCFAllocatorDefault,
            frame.pixelBuffer,
            formatDesc,
            &timingInfo,
            &sampleBuffer
        )

        guard status == noErr, let buffer = sampleBuffer else {
            return
        }

        // Send to client
        do {
            try stream.sendFrame(buffer)
            frameQueueLock.lock()
            pendingFrames.removeFirst()
            frameQueueLock.unlock()
        } catch {
            print("AnonCam Stream: Failed to send frame: \(error)")
        }
    }

    // MARK: - Format Control

    var activeFormat: CMFormatDescription? {
        guard activeFormatIndex < formatDescriptions.count else { return nil }
        return formatDescriptions[activeFormatIndex]
    }

    func setActiveFormat(_ format: CMFormatDescription) {
        if let index = formatDescriptions.firstIndex(of: format) {
            activeFormatIndex = index
        }
    }
}

// MARK: - CMIOExtensionStreamSource

extension ExtensionStreamSource: CMIOExtensionStreamSource {

    var streamID: String {
        "com.anoncam.stream.source"
    }

    var streamLocalizedName: String {
        "AnonCam"
    }

    var streamType: CMIOExtensionStreamType {
        .some(.video)
    }

    var direction: CMIOExtensionStreamDirection {
        .source // We output frames
    }

    var hasActiveControl: Bool {
        true
    }

    func streamProperties() async throws -> [String: Any] {
        var properties: [String: Any] = [:]

        if let activeFormat = activeFormat {
            properties[kCMIODevicePropertyFormatOverride as String] = activeFormat
        }

        properties[kCMIODevicePropertyDeviceIsRunningSomewhereElse as String] = false

        return properties
    }

    func setStreamProperties(_ properties: [String: Any]?) async throws {
        guard let properties = properties else { return }

        if let format = properties[kCMIODevicePropertyFormatOverride as String] as? CMFormatDescription {
            setActiveFormat(format)
        }
    }

    func authorizedToStartStream() async throws -> Bool {
        true
    }

    func startStream() async throws {
        deviceSource?.startStreaming()
    }

    func stopStream() async throws {
        deviceSource?.stopStreaming()
    }

    var beginSequenceNumber: Int64 {
        1
    }

    var minFrameDuration: CMTime {
        CMTime(value: 1, timescale: 30)
    }

    var activeVideoFormatDescription: CMFormatDescription? {
        activeFormat
    }

    func setActiveVideoFormatDescription(_ formatDescription: CMFormatDescription?, maxFrameDuration: CMTime) async throws {
        if let format = formatDescription {
            setActiveFormat(format)
        }
    }

    func setControl(_ control: CMIOExtensionControl, value: Any) async throws {
        // Handle control changes (brightness, contrast, etc.)
    }
}

// MARK: - Sink Stream Pattern (Alternative)

/// Alternative: Use sink stream for app to push frames directly
/// This follows the Apple sample pattern where the app pushes to a sink
@objc(ExtensionSinkStreamSource)
class ExtensionSinkStreamSource: NSObject {

    /// Receive frames from app via sink stream
    func enqueueSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // Forward to source stream
        // In this pattern, the extension has both sink and source streams
    }

    /// Flush pending frames
    func flush() {
        // Clear any pending frames
    }
}
