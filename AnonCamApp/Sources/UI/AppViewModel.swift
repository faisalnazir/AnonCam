//
//  AppViewModel.swift
//  AnonCam
//
//  View model coordinating capture, face tracking, and rendering
//

import AppKit
import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import Foundation
import Metal

/// Main view model that orchestrates the camera processing pipeline
@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var status: String = "Ready"
    @Published var isRunning: Bool = false
    @Published var fps: Double = 0
    @Published var resolution: CGSize = .zero
    @Published var hasPermission: Bool = false
    @Published var previewImage: NSImage?  // For live preview

    // Camera selection
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCameraId: String = ""

    // MARK: - Components (Thread-confined to processingQueue)

    private nonisolated(unsafe) var cameraCapture: CameraCapture?
    private nonisolated(unsafe) var faceTracker: VisionFaceTracker?
    private nonisolated(unsafe) var metalRenderer: MetalRenderer?
    private nonisolated(unsafe) var frameExporter: FrameExporter?
    private nonisolated(unsafe) var faceMeshMapper: FaceMeshMapper?

    // Concurrency & Throttling
    private let processingQueue = DispatchQueue(label: "com.anoncam.processing", qos: .userInteractive)
    private let processingSemaphore = DispatchSemaphore(value: 1)
    private let uiSemaphore = DispatchSemaphore(value: 1) // Throttle UI updates

    // Cached CIContext for efficient image conversion
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - Settings

    var maskColor: SIMD4<Float> = SIMD4<Float>(0.2, 0.25, 0.3, 1.0) {
        didSet {
            let newColor = maskColor // Capture value
            processingQueue.async { [weak self] in
                self?.metalRenderer?.maskColor = newColor
            }
        }
    }
    
    @Published var maskScale: Float = 1.0 {
        didSet {
            let newScale = maskScale
            processingQueue.async { [weak self] in
                self?.metalRenderer?.maskScale = newScale
            }
        }
    }

    var maskStyle: MaskStyle = .pixelate {
        didSet {
            let newStyle = maskStyle
            processingQueue.async { [weak self] in
                guard let self = self else { return }
                
                // Configure Renderer based on style
                self.metalRenderer?.isPixelationEnabled = (newStyle == .pixelate)
                self.metalRenderer?.is3DMaskEnabled = (newStyle == .helmet || newStyle == .organic || newStyle == .lowPoly || newStyle == .circle || newStyle == .sticker || newStyle == .faceMesh)
                self.metalRenderer?.isStickerMode = (newStyle == .sticker || newStyle == .faceMesh)
                self.metalRenderer?.isDebugEnabled = (newStyle == .debug)
                self.metalRenderer?.useFaceMeshMapping = (newStyle == .faceMesh)
                
                // Only update geometry if using a 3D mask
                if newStyle != .pixelate && newStyle != .none && newStyle != .debug {
                    self.metalRenderer?.maskGeometry = newStyle.geometry
                }
            }
        }
    }

    enum MaskStyle: String, CaseIterable {
        case pixelate = "Pixelate"
        case helmet = "Helmet"
        case organic = "Organic"
        case lowPoly = "Low Poly"
        case circle = "Circle"
        case sticker = "Sticker"
        case faceMesh = "Face Mesh"
        case debug = "Debug"
        case none = "None"

        var geometry: MaskGeometry {
            switch self {
            case .helmet: return .helmetMask()
            case .organic: return .organicMask()
            case .lowPoly: return .lowPolyMask()
            case .circle: return .circleMask()
            case .sticker: return .stickerMask()
            case .faceMesh: return .stickerMask() // Will be updated dynamically
            default: return .helmetMask()
            }
        }
    }

    // MARK: - Performance Tracking

    private var frameCount: Int = 0
    private var lastFpsUpdate: CFTimeInterval = 0
    private let fpsUpdateInterval: CFTimeInterval = 0.5

    // Tracking metrics
    @Published var trackingLatency: Double = 0  // ms
    @Published var trackingQuality: String = "Unknown"

    private var lastTrackingStart: CFTimeInterval = 0

    // Permission
    var permissionGranted: Bool = false {
        didSet {
            hasPermission = permissionGranted
            if permissionGranted {
                status = "Camera permission granted"
            } else {
                status = "Camera permission denied"
            }
        }
    }

    // MARK: - Initialization

    init() {
        setupComponents()
    }

    private func setupComponents() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            status = "Metal not available"
            return
        }

        // Create components
        cameraCapture = CameraCapture()
        faceTracker = VisionFaceTracker()
        metalRenderer = MetalRenderer(device: device)
        faceMeshMapper = FaceMeshMapper()
        
        // Share face mesh mapper with renderer
        metalRenderer?.faceMeshMapper = faceMeshMapper

        // Set up delegates
        cameraCapture?.delegate = self
        metalRenderer?.delegate = self

        // Discover available cameras
        discoverCameras()

        status = "Ready"
    }

    // MARK: - Camera Selection

    func discoverCameras() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = discoverySession.devices

        // Select first camera by default if none selected
        if selectedCameraId.isEmpty, let firstCamera = availableCameras.first {
            selectedCameraId = firstCamera.uniqueID
        }
    }

    func selectCamera(deviceId: String) {
        guard let device = availableCameras.first(where: { $0.uniqueID == deviceId }) else {
            return
        }

        selectedCameraId = deviceId

        // Perform reconfiguration on processing queue to avoid blocking main
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // If running, restart with new camera
            // Note: accessing isRunning (MainActor) is tricky here, but safe to just set device
            // The CameraCapture handles execution state internally
            self.cameraCapture?.setDevice(device)
            
            Task { @MainActor in
                self.status = "Camera: \(device.localizedName)"
            }
        }
    }

    // MARK: - Control

    func start() {
        guard permissionGranted else {
            status = "Camera permission required"
            return
        }

        guard !isRunning else { return }

        // Set selected camera before starting
        if let selectedCamera = availableCameras.first(where: { $0.uniqueID == selectedCameraId }) {
            cameraCapture?.setDevice(selectedCamera)
        }

        cameraCapture?.start()
        isRunning = true
        status = "Starting..."
    }

    func stop() {
        guard isRunning else { return }

        cameraCapture?.stop()
        isRunning = false
        status = "Stopped"
    }

    // MARK: - Frame Processing

    // MARK: - Frame Processing
    
    // Runs on background processingQueue
    private nonisolated func processFrame(pixelBuffer: CVPixelBuffer, at time: CMTime) {
        let startTime = CACurrentMediaTime()

        // 1. Track face using Vision framework
        guard let tracker = faceTracker else { return }

        let faceResult = tracker.processFrame(pixelBuffer)

        // Update tracking metrics
        let trackingTime = (CACurrentMediaTime() - startTime) * 1000
        
        // Update basic metrics on main actor (occasionally or always? Always is fine if cheap)
        Task { @MainActor in
             self.trackingLatency = trackingTime
             self.trackingQuality = faceResult.hasFace ? "Face detected (\(String(format: "%.1f", faceResult.confidence * 100))%)" : "No face"
             if faceResult.hasFace {
                 self.status = "Face detected"
             } else {
                 self.status = "No face"
             }
             self.updateFps()
        }

        // 2. Update resolution
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        // Check resolution change (optimization: check cached values first)
        // Since we are off-main, we shouldn't access `resolution` property directly.
        // We can check frameExporter's dimensions if it exists.
        if frameExporter == nil || frameExporter?.width != width || frameExporter?.height != height {
            if let device = metalRenderer?.device {
                 frameExporter = FrameExporter(
                    width: width,
                    height: height,
                    pixelFormat: kCVPixelFormatType_32BGRA,
                    metalDevice: device
                )
                // Update published property
                Task { @MainActor in
                    self.resolution = CGSize(width: width, height: height)
                }
            }
        }

        // 3. Render with mask overlay
        metalRenderer?.render(cameraPixelBuffer: pixelBuffer, faceResult: faceResult, at: time)
    }

    private func updateFps() {
        frameCount += 1
        let now = CACurrentMediaTime()

        if now - lastFpsUpdate >= fpsUpdateInterval {
            fps = Double(frameCount) / (now - lastFpsUpdate)
            frameCount = 0
            lastFpsUpdate = now
        }
    }

    // MARK: - Mask Styling

    func setMaskColor(_ color: NSColor) {
        maskColor = SIMD4<Float>(
            Float(color.redComponent),
            Float(color.greenComponent),
            Float(color.blueComponent),
            Float(color.alphaComponent)
        )
    }

    func cycleMaskStyle() {
        switch maskStyle {
        case .pixelate: maskStyle = .helmet
        case .helmet: maskStyle = .organic
        case .organic: maskStyle = .lowPoly
        case .lowPoly: maskStyle = .circle
        case .circle: maskStyle = .sticker
        case .sticker: maskStyle = .faceMesh
        case .faceMesh: maskStyle = .debug
        case .debug: maskStyle = .none
        case .none: maskStyle = .pixelate
        }
    }
    
    // MARK: - Texture Overlay
    
    /// Whether a face was detected in the loaded texture
    @Published var textureFaceDetected: Bool = false
    
    /// Load an image as a texture overlay for the 3D mask
    func loadMaskTexture(from image: NSImage) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Load texture into renderer
            self.metalRenderer?.loadMaskTexture(from: image)
            
            // Detect face in texture for face-to-face mapping
            let faceDetected = self.faceMeshMapper?.setTextureFace(from: image) ?? false
            
            Task { @MainActor in
                self.textureFaceDetected = faceDetected
                if faceDetected {
                    print("Face detected in texture - face mapping enabled")
                } else {
                    print("No face in texture - using standard UV mapping")
                }
            }
        }
    }
    
    /// Load a texture from a file URL
    func loadMaskTexture(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            print("Failed to load image from URL: \(url)")
            return
        }
        loadMaskTexture(from: image)
    }
    
    /// Clear the mask texture overlay
    func clearMaskTexture() {
        processingQueue.async { [weak self] in
            self?.metalRenderer?.clearMaskTexture()
        }
    }
}

extension AppViewModel: CameraCaptureDelegate {

    nonisolated func cameraCapture(_ capture: CameraCapture, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        // CVPixelBuffer is not Sendable, so we use nonisolated(unsafe)
        nonisolated(unsafe) let buffer = pixelBuffer
        
        // THROTTLING: Drop frame if processing queue is busy
        if processingSemaphore.wait(timeout: .now()) == .success {
            processingQueue.async { [weak self] in
                guard let self = self else { 
                    self?.processingSemaphore.signal()
                    return 
                }
                defer { self.processingSemaphore.signal() }
                
                autoreleasepool {
                    self.processFrame(pixelBuffer: buffer, at: time)
                }
            }
        } else {
            // Frame dropped for backpressure
        }
    }

    nonisolated func cameraCapture(_ capture: CameraCapture, didEncounter error: any Error) {
        let errorMessage = error.localizedDescription
        Task { @MainActor in
            self.status = "Error: \(errorMessage)"
        }
    }
}

// MARK: - MetalRendererDelegate

extension AppViewModel: MetalRendererDelegate {

    nonisolated func renderer(_ renderer: MetalRenderer, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Use MainActor to access shared ciContext and update UI
        // THROTTLING: Drop UI update if Main Thread is busy
        if uiSemaphore.wait(timeout: .now()) == .success {
            Task { @MainActor in
                defer { self.uiSemaphore.signal() }
                
                autoreleasepool {
                    if let cgImage = self.ciContext.createCGImage(ciImage, from: CGRect(x: 0, y: 0, width: width, height: height)) {
                        self.previewImage = NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
                    }
                }
            }
        }
    }
}
