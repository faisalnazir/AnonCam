//
//  VisionFaceTracker.swift
//  AnonCam
//
//  Face tracking using Apple's Vision framework (Neural Engine + GPU)
//

import CoreVideo
import Foundation
import Vision
import simd

// MARK: - Vision Face Tracker

/// Fast face tracking using Apple's Vision framework
/// Runs on the Neural Engine for optimal performance on Apple Silicon
final class VisionFaceTracker {

    // MARK: - Configuration

    struct Configuration {
        var maxFaces: Int = 1
        var requestRevision: Int = VNDetectFaceLandmarksRequestRevision3  // macOS 15+
    }

    // MARK: - Properties

    private let configuration: Configuration
    private var faceLandmarksRequest: VNDetectFaceLandmarksRequest
    private var faceDetectionRequest: VNDetectFaceRectanglesRequest
    private let processingQueue = DispatchQueue(label: "com.anoncam.vision", qos: .userInitiated)

    private var lastResult: FaceTrackingResult = .empty
    private var isProcessing = false

    // MARK: - Initialization

    init(configuration: Configuration = .init()) {
        self.configuration = configuration

        // Create requests without completion handlers first
        self.faceLandmarksRequest = VNDetectFaceLandmarksRequest()
        self.faceDetectionRequest = VNDetectFaceRectanglesRequest()

        // Now configure after all properties are initialized
        self.faceLandmarksRequest.revision = configuration.requestRevision
    }

    // MARK: - Public API

    /// Process a camera frame and extract face landmarks synchronously
    func processFrame(_ pixelBuffer: CVPixelBuffer) -> FaceTrackingResult {
        // Return cached result if still processing
        guard !isProcessing else {
            return lastResult
        }

        isProcessing = true

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        do {
            try handler.perform([faceLandmarksRequest])

            // Process results directly after perform completes
            if let observations = faceLandmarksRequest.results,
               let faceObservation = observations.first {
                let result = convertFaceObservation(faceObservation)
                lastResult = result
            } else {
                lastResult = .empty
            }
        } catch {
            print("Vision error: \(error)")
            lastResult = .empty
        }

        isProcessing = false
        return lastResult
    }

    /// Process frame with completion handler (async version)
    func processFrame(_ pixelBuffer: CVPixelBuffer, completion: @escaping @Sendable (FaceTrackingResult) -> Void) {
        processingQueue.async { [weak self] in
            guard let self = self else {
                completion(.empty)
                return
            }

            let result = self.processFrame(pixelBuffer)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    /// Reset tracking state
    func reset() {
        lastResult = .empty
    }

    // MARK: - Conversion

    private func convertFaceObservation(_ observation: VNFaceObservation) -> FaceTrackingResult {
        guard let landmarks = observation.landmarks else {
            return FaceTrackingResult(
                hasFace: true,
                confidence: Float(observation.confidence),
                landmarks: [],
                pose: .identity,
                keyPoints: .empty,
                boundingBox: .zero
            )
        }

        // Convert all landmarks
        var allLandmarks: [Landmark] = []

        // Vision provides multiple landmark regions
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.allPoints))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.faceContour))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.leftEye))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.rightEye))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.leftEyebrow))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.rightEyebrow))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.nose))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.noseCrest))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.medianLine))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.leftPupil))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.rightPupil))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.outerLips))
        allLandmarks.append(contentsOf: convertLandmarkRegion(landmarks.innerLips))

        // Extract key points
        let keyPoints = extractKeyPoints(from: landmarks, boundingBox: observation.boundingBox)

        // Compute head pose
        let pose = computeHeadPose(from: observation, landmarks: landmarks)

        // Vision bounding box is normalized, origin bottom-left. 
        // We flip Y for Metal texture coordinates (origin top-left).
        let bbox = observation.boundingBox
        let flippedY = 1.0 - (bbox.origin.y + bbox.size.height)
        let metalRect = CGRect(x: bbox.origin.x, y: flippedY, width: bbox.size.width, height: bbox.size.height)

        return FaceTrackingResult(
            hasFace: true,
            confidence: Float(observation.confidence),
            landmarks: allLandmarks,
            pose: pose,
            keyPoints: keyPoints,
            boundingBox: metalRect
        )
    }

    private func convertLandmarkRegion(_ region: VNFaceLandmarkRegion2D?) -> [Landmark] {
        guard let region = region else { return [] }

        return region.normalizedPoints.map { point in
            Landmark(x: Float(point.x), y: Float(1.0 - point.y), z: 0) // Flip Y for Metal
        }
    }

    // MARK: - Key Points Extraction

    private func extractKeyPoints(from landmarks: VNFaceLandmarks2D, boundingBox: CGRect) -> KeyPoints {
        // Helper to get point at index
        func point(at index: Int, region: VNFaceLandmarkRegion2D?) -> Landmark {
            guard let region = region, index < region.pointCount else {
                return Landmark(x: 0.5, y: 0.5, z: 0)
            }
            let p = region.normalizedPoints[index]
            return Landmark(x: Float(p.x), y: Float(1.0 - p.y), z: 0)
        }

        // Extract specific landmark indices based on Vision's topology
        let leftEye = point(at: 0, region: landmarks.leftPupil)
        let rightEye = point(at: 0, region: landmarks.rightPupil)

        // Nose tip (outer nose point)
        let noseTip = landmarks.noseCrest?.normalizedPoints.last.map {
            Landmark(x: Float($0.x), y: Float(1.0 - $0.y), z: 0)
        } ?? Landmark(x: 0.5, y: 0.5, z: 0)

        // Upper lip
        let upperLip = point(at: 0, region: landmarks.outerLips)

        // Chin (lowest face contour point)
        let chin = landmarks.faceContour?.normalizedPoints.last.map {
            Landmark(x: Float($0.x), y: Float(1.0 - $0.y), z: 0)
        } ?? Landmark(x: 0.5, y: 0.5, z: 0)

        // Forehead (estimate from bounding box)
        let forehead = Landmark(
            x: Float(boundingBox.midX),
            y: Float(1.0 - (boundingBox.minY - 0.05)), // Slightly above bounding box
            z: 0
        )

        // Ears (estimate from face contour)
        let leftEar = landmarks.faceContour?.normalizedPoints.first.map {
            Landmark(x: Float($0.x), y: Float(1.0 - $0.y), z: 0)
        } ?? Landmark(x: 0.5, y: 0.5, z: 0)

        let rightEar = landmarks.faceContour?.normalizedPoints.last.map {
            Landmark(x: Float($0.x), y: Float(1.0 - $0.y), z: 0)
        } ?? Landmark(x: 0.5, y: 0.5, z: 0)

        return KeyPoints(
            leftEye: leftEye,
            rightEye: rightEye,
            noseTip: noseTip,
            upperLip: upperLip,
            chin: chin,
            leftEar: leftEar,
            rightEar: rightEar,
            forehead: forehead
        )
    }

    // MARK: - Head Pose Computation

    private func computeHeadPose(from observation: VNFaceObservation, landmarks: VNFaceLandmarks2D) -> HeadPose {
        var pose = HeadPose.translation // Initialize with translation values

        // Use Vision's built-in pose if available (iOS 17+ / macOS 14+)
        if let pitch = observation.pitch?.floatValue {
            pose.rotation.x = pitch
        }
        if let yaw = observation.yaw?.floatValue {
            pose.rotation.y = yaw
        }
        if let roll = observation.roll?.floatValue {
            pose.rotation.z = roll
        }

        // Compute translation from bounding box center
        // Vision coordinates: origin bottom-left, Y goes up
        // Metal NDC: origin center, X/Y in [-1, 1]
        // Convert Vision [0,1] to NDC [-1,1]
        let centerX = Float(observation.boundingBox.midX) * 2.0 - 1.0
        let centerY = Float(observation.boundingBox.midY) * 2.0 - 1.0
        let size = Float(observation.boundingBox.width)

        pose.translation = SIMD3<Float>(
            centerX,  // Already in NDC [-1, 1]
            centerY,  // Vision Y is bottom-up, NDC is also bottom-up, no flip needed
            size      // Face width as depth/scale proxy
        )

        // Build model matrix from rotation
        pose.modelMatrix = matrix_identity_float4x4

        // Apply rotation (pitch, yaw, roll)
        var rotationX = matrix_identity_float4x4
        rotationX.columns.0 = SIMD4<Float>(1, 0, 0, 0)
        rotationX.columns.1 = SIMD4<Float>(0, cos(pose.rotation.x), sin(pose.rotation.x), 0)
        rotationX.columns.2 = SIMD4<Float>(0, -sin(pose.rotation.x), cos(pose.rotation.x), 0)

        var rotationY = matrix_identity_float4x4
        rotationY.columns.0 = SIMD4<Float>(cos(pose.rotation.y), 0, -sin(pose.rotation.y), 0)
        rotationY.columns.1 = SIMD4<Float>(0, 1, 0, 0)
        rotationY.columns.2 = SIMD4<Float>(sin(pose.rotation.y), 0, cos(pose.rotation.y), 0)

        var rotationZ = matrix_identity_float4x4
        rotationZ.columns.0 = SIMD4<Float>(cos(pose.rotation.z), sin(pose.rotation.z), 0, 0)
        rotationZ.columns.1 = SIMD4<Float>(-sin(pose.rotation.z), cos(pose.rotation.z), 0, 0)
        rotationZ.columns.2 = SIMD4<Float>(0, 0, 1, 0)

        pose.modelMatrix = rotationZ * rotationY * rotationX

        // Translation will be applied in MetalRenderer using bounding box directly
        // Store translation for reference but don't bake into modelMatrix
        pose.modelMatrix.columns.3 = SIMD4<Float>(0, 0, 0, 1)

        return pose
    }
}

// MARK: - HeadPose Extension

extension HeadPose {
    static var translation: HeadPose {
        HeadPose(
            translation: .zero,
            rotation: .zero,
            modelMatrix: matrix_identity_float4x4
        )
    }
}
