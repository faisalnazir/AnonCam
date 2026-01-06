//
//  CameraCapture.swift
//  AnonCam
//
//  Captures camera frames using AVCaptureSession and provides them to delegate
//

import AVFoundation
import CoreVideo
import Foundation

/// Protocol for receiving captured camera frames
protocol CameraCaptureDelegate: AnyObject {
    func cameraCapture(_ capture: CameraCapture, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime)
    func cameraCapture(_ capture: CameraCapture, didEncounter error: any Error)
}

/// Configuration for camera capture
struct CameraCaptureConfiguration {
    var preset: AVCaptureSession.Preset = .high
    var frameRate: CMTimeScale = 30
    var prefersHardwareAcceleration: Bool = true
    var colorSpace: AVCaptureColorSpace = .sRGB

    static let `default` = CameraCaptureConfiguration()
}

/// Captures video from the default camera device
final class CameraCapture: NSObject, @unchecked Sendable {

    // MARK: - Properties

    private(set) var session: AVCaptureSession
    private let config: CameraCaptureConfiguration

    private var videoOutput: AVCaptureVideoDataOutput?
    private var videoInput: AVCaptureDeviceInput?

    private let sessionQueue = DispatchQueue(label: "com.anoncam.camera.session", qos: .userInitiated)
    private let callbackQueue = DispatchQueue(label: "com.anoncam.camera.callback", qos: .userInitiated)

    weak var delegate: (any CameraCaptureDelegate)?

    var isRunning: Bool {
        session.isRunning
    }

    var currentDevice: AVCaptureDevice? {
        videoInput?.device
    }

    // MARK: - Initialization

    init(config: CameraCaptureConfiguration = .default) {
        self.config = config
        self.session = AVCaptureSession()

        super.init()

        sessionQueue.sync { [weak self] in
            self?.setupSession()
        }
    }

    deinit {
        stopSession()
    }

    // MARK: - Setup

    private func setupSession() {
        session.beginConfiguration()

        // Set preset
        session.sessionPreset = config.preset

        // Try to get any available video device - prefer built-in, fall back to any
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )

        if let videoDevice = discoverySession.devices.first {
            do {
                videoInput = try AVCaptureDeviceInput(device: videoDevice)
                if let videoInput = videoInput {
                    if session.canAddInput(videoInput) {
                        session.addInput(videoInput)
                    }
                    // Configure frame rate
                    configureFrameRate(for: videoDevice, targetFps: Int32(config.frameRate))
                }
            } catch {
                print("Failed to create video input: \(error)")
            }
        } else {
            print("No video device available at init time - will be set via setDevice()")
        }

        // Add video output (always set this up)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: callbackQueue)

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        videoOutput = output

        // Set video connection properties if available
        if let connection = output.connection(with: .video) {
            connection.videoRotationAngle = 0
            connection.automaticallyAdjustsVideoMirroring = false
        }

        session.commitConfiguration()
    }

    private func configureFrameRate(for device: AVCaptureDevice, targetFps: Int32) {
        guard device.activeFormat.isFrameRateSupported(targetFps) else {
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: targetFps)
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: targetFps)
            device.unlockForConfiguration()
        } catch {
            print("Failed to configure frame rate: \(error)")
        }
    }

    // MARK: - Control

    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    private func stopSession() {
        session.stopRunning()
    }

    // MARK: - Device Management

    func switchCamera(to position: AVCaptureDevice.Position) throws {
        sessionQueue.sync { [weak self] in
            guard let self = self else { return }

            self.session.beginConfiguration()

            // Remove current input
            if let currentInput = self.videoInput {
                self.session.removeInput(currentInput)
            }

            // Find new device
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
                self.session.commitConfiguration()
                return  // Can't throw from sync closure
            }

            // Create new input
            guard let newInput = try? AVCaptureDeviceInput(device: device) else {
                self.session.commitConfiguration()
                return
            }

            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput

                // Configure frame rate
                self.configureFrameRate(for: device, targetFps: Int32(self.config.frameRate))
            }

            // Update output connection
            if let connection = self.videoOutput?.connection(with: .video) {
                connection.isVideoMirrored = (position == .front)
            }

            self.session.commitConfiguration()
        }
    }

    func setMirrored(_ mirrored: Bool) {
        sessionQueue.sync { [weak self] in
            guard let connection = self?.videoOutput?.connection(with: .video) else { return }
            connection.isVideoMirrored = mirrored
        }
    }

    /// Switch to a specific capture device
    func setDevice(_ device: AVCaptureDevice) {
        sessionQueue.sync { [weak self] in
            guard let self = self else { return }

            self.session.beginConfiguration()

            // Remove current input
            if let currentInput = self.videoInput {
                self.session.removeInput(currentInput)
            }

            // Create new input
            guard let newInput = try? AVCaptureDeviceInput(device: device) else {
                self.session.commitConfiguration()
                return
            }

            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput

                // Configure frame rate
                self.configureFrameRate(for: device, targetFps: Int32(self.config.frameRate))
            }

            // Update output connection for mirroring
            if let connection = self.videoOutput?.connection(with: .video) {
                connection.isVideoMirrored = (device.position == .front)
            }

            self.session.commitConfiguration()
        }
    }

    // MARK: - Errors

    enum CameraError: LocalizedError {
        case deviceNotFound
        case authorizationDenied
        case configurationFailed

        var errorDescription: String? {
            switch self {
            case .deviceNotFound:
                return "Camera device not found"
            case .authorizationDenied:
                return "Camera access denied"
            case .configurationFailed:
                return "Failed to configure camera"
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraCapture: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        delegate?.cameraCapture(self, didOutput: pixelBuffer, at: timestamp)
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Frame dropped - could log or track drop rate
    }
}

// MARK: - AVCaptureDevice Format Extension

private extension AVCaptureDevice.Format {
    func isFrameRateSupported(_ frameRate: Int32) -> Bool {
        videoSupportedFrameRateRanges.contains { $0.includesFrameRate(frameRate) }
    }
}

private extension AVFrameRateRange {
    func includesFrameRate(_ frameRate: Int32) -> Bool {
        Float64(frameRate) >= minFrameRate && Float64(frameRate) <= maxFrameRate
    }
}
