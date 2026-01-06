#!/usr/bin/env swift
//
//  QuickTest.swift
//  AnonCam - Quick camera + Vision test
//
//  Run: swift QuickTest.swift
//  Or: chmod +x QuickTest.swift && ./QuickTest.swift
//

import Cocoa
import AVFoundation
import Vision
import Metal

// MARK: - Simple Camera Test

print("🎥 AnonCam Quick Test")
print("===================")

// Check Metal
guard let _ = MTLCreateSystemDefaultDevice() else {
    print("❌ Metal not available")
    exit(1)
}
print("✅ Metal available")

// Check Vision
print("✅ Vision framework available")

// Request camera permission
print("\n📷 Requesting camera permission...")

let semaphore = DispatchSemaphore(value: 0)

AVCaptureDevice.requestAccess(for: .video) { granted in
    if granted {
        print("✅ Camera permission granted")
    } else {
        print("❌ Camera permission denied")
        exit(1)
    }
    semaphore.signal()
}

semaphore.wait()

// Try to create capture session
print("\n🔧 Setting up capture session...")

let captureSession = AVCaptureSession()

guard let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
    print("❌ No camera device found")
    exit(1)
}

print("✅ Found camera: \(videoDevice.localizedName)")

// Create input
do {
    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
    if captureSession.canAddInput(videoInput) {
        captureSession.addInput(videoInput)
        print("✅ Camera input added")
    }
} catch {
    print("❌ Failed to create camera input: \(error)")
    exit(1)
}

// Create output
let videoOutput = AVCaptureVideoDataOutput()
videoOutput.setSampleBufferDelegate(nil, queue: DispatchQueue(label: "camera"))

if captureSession.canAddOutput(videoOutput) {
    captureSession.addOutput(videoOutput)
    print("✅ Video output added")
}

// Start session
print("\n🎬 Starting capture session (3 seconds)...")
captureSession.startRunning()

// Capture a few frames
var frameCount = 0
let testDuration: TimeInterval = 3
let startTime = Date()

videoOutput.setSampleBufferDelegate(CaptureDelegate(), queue: DispatchQueue(label: "camera"))

RunLoop.main.run(until: Date(timeIntervalSinceNow: testDuration))

captureSession.stopRunning()
print("\n✅ Test complete!")

// MARK: - Capture Delegate

class CaptureDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameCount += 1

        // Get pixel buffer
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if frameCount == 1 {
            print("   Frame 1: \(width) x \(height)")

            // Test Vision on first frame
            testFaceDetection(pixelBuffer: pixelBuffer)
        }

        if frameCount % 30 == 0 {
            print("   Frames: \(frameCount)")
        }
    }

    func testFaceDetection(pixelBuffer: CVPixelBuffer) {
        print("\n🤖 Testing Vision face detection...")

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let request = VNDetectFaceRectanglesRequest()

        do {
            try handler.perform([request])

            if let faces = request.results, !faces.isEmpty {
                print("✅ Detected \(faces.count) face(s)")

                // Try face landmarks
                testFaceLandmarks(pixelBuffer: pixelBuffer)
            } else {
                print("ℹ️  No face detected (point camera at your face)")
            }
        } catch {
            print("❌ Vision error: \(error)")
        }
    }

    func testFaceLandmarks(pixelBuffer: CVPixelBuffer) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        let request = VNDetectFaceLandmarksRequest { request, error in
            guard let observations = request.results as? [VNFaceObservation], let face = observations.first else {
                print("   No landmarks detected")
                return
            }

            print("✅ Face landmarks detected:")
            print("   - Confidence: \(String(format: "%.1f%%", face.confidence * 100))")

            if face.landmarks != nil {
                var landmarkCount = 0
                if let allPoints = face.landmarks?.allPoints { landmarkCount += allPoints.pointCount }
                if let leftEye = face.landmarks?.leftEye { landmarkCount += leftEye.pointCount }
                if let rightEye = face.landmarks?.rightEye { landmarkCount += rightEye.pointCount }
                if let nose = face.landmarks?.nose { landmarkCount += nose.pointCount }
                if let mouth = face.landmarks?.outerLips { landmarkCount += mouth.pointCount }
                print("   - Total landmarks: ~\(landmarkCount)")
            }

            if let roll = face.roll, let yaw = face.yaw {
                print("   - Head pose: roll=\(String(format: "%.2f", roll)), yaw=\(String(format: "%.2f", yaw))")
            }
        }

        try? handler.perform([request])
    }
}
