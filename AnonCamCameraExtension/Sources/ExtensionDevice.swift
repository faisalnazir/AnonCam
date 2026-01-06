//
//  ExtensionDevice.swift
//  AnonCamCameraExtension
//
//  CoreMediaIO Extension Device Source - represents a virtual camera device
//

import CoreMediaIO
import Foundation

/// The device source represents a single camera device
/// It manages streams and handles device-level properties
class ExtensionDeviceSource: NSObject {

    // MARK: - Properties

    private(set) var streamSource: ExtensionStreamSource!

    weak var client: CMIOExtensionClient?

    private var _device: CMIOExtensionDevice?
    var device: CMIOExtensionDevice? {
        get { _device }
        set { _device = newValue }
    }

    // MARK: - Device Properties

    var deviceID: String {
        "com.anoncam.device.source"
    }

    var deviceModel: String {
        "AnonCam Virtual Camera"
    }

    var manufacturer: String {
        "AnonCam"
    }

    var deviceLocalizedName: String {
        "AnonCam"
    }

    // MARK: - State

    private(set) var isStreaming = false

    // MARK: - Frame Source (IPC)

    private var frameRingBuffer: FrameRingBuffer?
    private var frameTimer: DispatchSourceTimer?
    private let frameQueue = DispatchQueue(label: "com.anoncam.device.frames")

    // MARK: - Initialization

    override init() {
        super.init()
        setupStreamSource()
        setupIPC()
    }

    private func setupStreamSource() {
        // Create the stream source with supported formats
        self.streamSource = ExtensionStreamSource(deviceSource: self)
    }

    private func setupIPC() {
        // Attach to shared memory ring buffer created by main app
        // The app should have created this at a known location

        let shmPath = "/tmp/com.anoncam.shm"
        if let ringBuffer = FrameRingBuffer.attachMappedFile(at: shmPath) {
            self.frameRingBuffer = ringBuffer
            print("AnonCam Extension: Attached to shared memory at \(shmPath)")
        } else {
            print("AnonCam Extension: Failed to attach to shared memory, app may not be running")
        }
    }

    // MARK: - Streaming Control

    func startStreaming() {
        guard !isStreaming else { return }
        isStreaming = true
        streamSource.startStreaming()
        startFrameDelivery()
    }

    func stopStreaming() {
        guard isStreaming else { return }
        isStreaming = false
        streamSource.stopStreaming()
        stopFrameDelivery()
    }

    private func startFrameDelivery() {
        // Start delivering frames from ring buffer to stream
        frameTimer = DispatchSource.makeTimerSource(queue: frameQueue)
        frameTimer?.setEventHandler { [weak self] in
            self?.deliverNextFrame()
        }
        frameTimer?.schedule(deadline: .now(), repeating: .milliseconds(33)) // ~30 FPS
        frameTimer?.resume()
    }

    private func stopFrameDelivery() {
        frameTimer?.cancel()
        frameTimer = nil
    }

    private func deliverNextFrame() {
        guard let frame = frameRingBuffer?.readFrame() else {
            return
        }

        // Deliver to stream
        streamSource.queueFrame(frame.pixelBuffer, at: frame.timestamp)
    }

    // MARK: - Properties

    func updateProperties(_ properties: [String: Any]) {
        // Handle property updates from client
        if let format = properties[kCMIODevicePropertyFormatOverride as String] as? NSDictionary {
            // Format change requested
        }
    }
}

// MARK: - CMIOExtensionDeviceSource

extension ExtensionDeviceSource: CMIOExtensionDeviceSource {

    var deviceIDForClient: String {
        deviceID
    }

    var deviceModelID: String {
        "AnonCam-1"
    }

    var deviceTransportType: CMIOExtensionDeviceTransportType {
        .builtIn
    }

    var deviceType: CMIOExtensionDeviceType {
        .some(.video)
    }

    func streamSource(for stream: CMIOExtensionStream) -> CMIOExtensionStreamSource? {
        stream.streamSource as? CMIOExtensionStreamSource
    }

    var streamSources: [CMIOExtensionStreamSource] {
        [streamSource]
    }

    var supportedControls: [CMIOExtensionControl] {
        // Basic camera controls
        []
    }

    func control(for controlID: UInt64) -> CMIOExtensionControl? {
        nil
    }

    func setDeviceProperties(_ properties: [String: Any]?) async throws {
        guard let properties = properties else { return }

        if let format = properties[kCMIODevicePropertyFormatOverride as String] {
            // Handle format change
            print("AnonCam: Format override requested: \(format)")
        }

        if let suspended = properties[kCMIODevicePropertyDeviceIsRunningSomewhereElse as String] as? Bool {
            print("AnonCam: Device running elsewhere: \(suspended)")
        }
    }

    func deviceProperties() async throws -> [String: Any] {
        [
            kCMIODevicePropertyModelUID as String: deviceModelID,
            kCMIODevicePropertyTransportType as String: deviceTransportType.rawValue,
            kCMIODevicePropertyDeviceIsRunningSomewhereElse as String: false
        ]
    }
}
