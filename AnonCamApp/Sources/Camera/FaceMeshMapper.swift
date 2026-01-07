//
//  FaceMeshMapper.swift
//  AnonCam
//
//  Face mesh detection and texture-to-face mapping
//  Detects faces in texture images and maps them onto live face landmarks
//

import AppKit
import CoreGraphics
import Vision
import simd

// MARK: - Face Mesh Points

/// Standard 68-point face landmark indices (similar to dlib/OpenCV)
enum FaceMeshPoint: Int, CaseIterable {
    // Jaw line (0-16)
    case jaw0 = 0, jaw1, jaw2, jaw3, jaw4, jaw5, jaw6, jaw7, jaw8
    case jaw9, jaw10, jaw11, jaw12, jaw13, jaw14, jaw15, jaw16
    
    // Right eyebrow (17-21)
    case rightEyebrow0 = 17, rightEyebrow1, rightEyebrow2, rightEyebrow3, rightEyebrow4
    
    // Left eyebrow (22-26)
    case leftEyebrow0 = 22, leftEyebrow1, leftEyebrow2, leftEyebrow3, leftEyebrow4
    
    // Nose bridge (27-30)
    case noseBridge0 = 27, noseBridge1, noseBridge2, noseBridge3
    
    // Nose bottom (31-35)
    case noseBottom0 = 31, noseBottom1, noseBottom2, noseBottom3, noseBottom4
    
    // Right eye (36-41)
    case rightEye0 = 36, rightEye1, rightEye2, rightEye3, rightEye4, rightEye5
    
    // Left eye (42-47)
    case leftEye0 = 42, leftEye1, leftEye2, leftEye3, leftEye4, leftEye5
    
    // Outer lips (48-59)
    case outerLips0 = 48, outerLips1, outerLips2, outerLips3, outerLips4, outerLips5
    case outerLips6, outerLips7, outerLips8, outerLips9, outerLips10, outerLips11
    
    // Inner lips (60-67)
    case innerLips0 = 60, innerLips1, innerLips2, innerLips3
    case innerLips4, innerLips5, innerLips6, innerLips7
}

// MARK: - Face Mesh Result

/// Detected face mesh with normalized landmark positions
struct FaceMesh {
    /// All landmark points in normalized coordinates [0,1]
    let points: [SIMD2<Float>]
    
    /// Bounding box of the face
    let boundingBox: CGRect
    
    /// Confidence score
    let confidence: Float
    
    /// Get point by index
    subscript(index: Int) -> SIMD2<Float> {
        guard index < points.count else { return SIMD2<Float>(0.5, 0.5) }
        return points[index]
    }
    
    /// Get point by mesh point enum
    subscript(point: FaceMeshPoint) -> SIMD2<Float> {
        self[point.rawValue]
    }
    
    /// Center of the face
    var center: SIMD2<Float> {
        SIMD2<Float>(Float(boundingBox.midX), Float(boundingBox.midY))
    }
    
    /// Eye center (midpoint between eyes)
    var eyeCenter: SIMD2<Float> {
        guard points.count > 45 else { return center }
        let leftEye = points[42]  // Left eye inner corner
        let rightEye = points[39] // Right eye inner corner
        return (leftEye + rightEye) * 0.5
    }
    
    /// Inter-ocular distance (for scale normalization)
    var interOcularDistance: Float {
        guard points.count > 45 else { return 0.2 }
        let leftEye = points[42]
        let rightEye = points[39]
        return length(leftEye - rightEye)
    }
    
    static let empty = FaceMesh(points: [], boundingBox: .zero, confidence: 0)
}

// MARK: - Face Mesh Mapper

/// Detects faces in images and creates UV mappings for face-to-face texture transfer
final class FaceMeshMapper {
    
    // MARK: - Properties
    
    private let landmarksRequest: VNDetectFaceLandmarksRequest
    
    /// Cached texture face mesh
    private(set) var textureFaceMesh: FaceMesh?
    
    // MARK: - Initialization
    
    init() {
        self.landmarksRequest = VNDetectFaceLandmarksRequest()
        self.landmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3
    }
    
    // MARK: - Face Detection in Images
    
    /// Detect face mesh in an NSImage (for texture images)
    func detectFace(in image: NSImage) -> FaceMesh? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        return detectFace(in: cgImage)
    }
    
    /// Detect face mesh in a CGImage
    func detectFace(in cgImage: CGImage) -> FaceMesh? {
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([landmarksRequest])
            
            guard let results = landmarksRequest.results,
                  let face = results.first,
                  let landmarks = face.landmarks else {
                return nil
            }
            
            return convertToFaceMesh(face: face, landmarks: landmarks)
        } catch {
            print("Face detection error: \(error)")
            return nil
        }
    }
    
    /// Store detected face from texture for mapping
    func setTextureFace(from image: NSImage) -> Bool {
        if let mesh = detectFace(in: image) {
            textureFaceMesh = mesh
            print("Texture face detected: \(mesh.points.count) points, confidence: \(mesh.confidence)")
            return true
        }
        textureFaceMesh = nil
        return false
    }
    
    // MARK: - Landmark Conversion
    
    private func convertToFaceMesh(face: VNFaceObservation, landmarks: VNFaceLandmarks2D) -> FaceMesh {
        var points: [SIMD2<Float>] = []
        
        // Build 68-point mesh from Vision landmarks
        // Vision provides different regions, we need to map them to standard 68-point format
        
        // Jaw/face contour (17 points: 0-16)
        if let contour = landmarks.faceContour {
            let contourPoints = extractPoints(from: contour, count: 17)
            points.append(contentsOf: contourPoints)
        } else {
            points.append(contentsOf: Array(repeating: SIMD2<Float>(0.5, 0.5), count: 17))
        }
        
        // Right eyebrow (5 points: 17-21)
        if let rightBrow = landmarks.rightEyebrow {
            let browPoints = extractPoints(from: rightBrow, count: 5)
            points.append(contentsOf: browPoints)
        } else {
            points.append(contentsOf: Array(repeating: SIMD2<Float>(0.5, 0.5), count: 5))
        }
        
        // Left eyebrow (5 points: 22-26)
        if let leftBrow = landmarks.leftEyebrow {
            let browPoints = extractPoints(from: leftBrow, count: 5)
            points.append(contentsOf: browPoints)
        } else {
            points.append(contentsOf: Array(repeating: SIMD2<Float>(0.5, 0.5), count: 5))
        }
        
        // Nose bridge (4 points: 27-30)
        if let noseCrest = landmarks.noseCrest {
            let nosePoints = extractPoints(from: noseCrest, count: 4)
            points.append(contentsOf: nosePoints)
        } else {
            points.append(contentsOf: Array(repeating: SIMD2<Float>(0.5, 0.5), count: 4))
        }
        
        // Nose bottom (5 points: 31-35)
        if let nose = landmarks.nose {
            let nosePoints = extractPoints(from: nose, count: 5)
            points.append(contentsOf: nosePoints)
        } else {
            points.append(contentsOf: Array(repeating: SIMD2<Float>(0.5, 0.5), count: 5))
        }
        
        // Right eye (6 points: 36-41)
        if let rightEye = landmarks.rightEye {
            let eyePoints = extractPoints(from: rightEye, count: 6)
            points.append(contentsOf: eyePoints)
        } else {
            points.append(contentsOf: Array(repeating: SIMD2<Float>(0.5, 0.5), count: 6))
        }
        
        // Left eye (6 points: 42-47)
        if let leftEye = landmarks.leftEye {
            let eyePoints = extractPoints(from: leftEye, count: 6)
            points.append(contentsOf: eyePoints)
        } else {
            points.append(contentsOf: Array(repeating: SIMD2<Float>(0.5, 0.5), count: 6))
        }
        
        // Outer lips (12 points: 48-59)
        if let outerLips = landmarks.outerLips {
            let lipPoints = extractPoints(from: outerLips, count: 12)
            points.append(contentsOf: lipPoints)
        } else {
            points.append(contentsOf: Array(repeating: SIMD2<Float>(0.5, 0.5), count: 12))
        }
        
        // Inner lips (8 points: 60-67)
        if let innerLips = landmarks.innerLips {
            let lipPoints = extractPoints(from: innerLips, count: 8)
            points.append(contentsOf: lipPoints)
        } else {
            points.append(contentsOf: Array(repeating: SIMD2<Float>(0.5, 0.5), count: 8))
        }
        
        // Convert bounding box (flip Y for standard coordinates)
        let bbox = face.boundingBox
        let flippedBox = CGRect(
            x: bbox.origin.x,
            y: 1.0 - bbox.origin.y - bbox.height,
            width: bbox.width,
            height: bbox.height
        )
        
        return FaceMesh(
            points: points,
            boundingBox: flippedBox,
            confidence: Float(face.confidence)
        )
    }
    
    /// Extract N points from a landmark region, resampling if needed
    private func extractPoints(from region: VNFaceLandmarkRegion2D, count: Int) -> [SIMD2<Float>] {
        let sourcePoints = region.normalizedPoints
        
        if sourcePoints.count == count {
            return sourcePoints.map { SIMD2<Float>(Float($0.x), Float(1.0 - $0.y)) }
        }
        
        // Resample to desired count
        var result: [SIMD2<Float>] = []
        for i in 0..<count {
            let t = Float(i) / Float(max(count - 1, 1))
            let sourceIndex = t * Float(sourcePoints.count - 1)
            let lowIndex = Int(sourceIndex)
            let highIndex = min(lowIndex + 1, sourcePoints.count - 1)
            let frac = sourceIndex - Float(lowIndex)
            
            let p1 = sourcePoints[lowIndex]
            let p2 = sourcePoints[highIndex]
            
            let x = Float(p1.x) * (1 - frac) + Float(p2.x) * frac
            let y = Float(1.0 - p1.y) * (1 - frac) + Float(1.0 - p2.y) * frac
            
            result.append(SIMD2<Float>(x, y))
        }
        
        return result
    }
    
    // MARK: - UV Mapping
    
    /// Generate UV coordinates that map texture face onto live face
    /// Uses landmark-to-landmark correspondence for accurate feature mapping
    func generateUVMapping(liveFace: FaceTrackingResult, maskVertices: [SIMD3<Float>]) -> [SIMD2<Float>] {
        guard let textureMesh = textureFaceMesh, textureMesh.points.count >= 68 else {
            // No texture face - return default UVs
            return maskVertices.map { vertex in
                SIMD2<Float>((vertex.x + 0.5), (vertex.y + 0.5))
            }
        }
        
        // Build live face mesh from landmarks
        let liveMesh = extractFaceMesh(from: liveFace)
        guard liveMesh.points.count >= 68 else {
            return maskVertices.map { vertex in
                SIMD2<Float>((vertex.x + 0.5), (vertex.y + 0.5))
            }
        }
        
        // Get key anchor points from both faces
        let liveAnchors = extractAnchorPoints(from: liveMesh)
        let textureAnchors = extractAnchorPoints(from: textureMesh)
        
        // Map each mask vertex to texture UV using barycentric interpolation
        return maskVertices.map { vertex in
            // Convert vertex from [-0.5, 0.5] to [0, 1] normalized space
            let normalizedPos = SIMD2<Float>(vertex.x + 0.5, vertex.y + 0.5)
            
            // Find which facial region this vertex belongs to and interpolate
            return mapPointToTexture(
                point: normalizedPos,
                liveAnchors: liveAnchors,
                textureAnchors: textureAnchors,
                liveBBox: liveFace.boundingBox,
                textureBBox: textureMesh.boundingBox
            )
        }
    }
    
    /// Key anchor points for face mapping
    struct FaceAnchors {
        var leftEye: SIMD2<Float>      // Center of left eye
        var rightEye: SIMD2<Float>     // Center of right eye
        var noseTip: SIMD2<Float>      // Tip of nose
        var leftMouth: SIMD2<Float>    // Left corner of mouth
        var rightMouth: SIMD2<Float>   // Right corner of mouth
        var chin: SIMD2<Float>         // Bottom of chin
        var leftCheek: SIMD2<Float>    // Left cheek (jaw point)
        var rightCheek: SIMD2<Float>   // Right cheek (jaw point)
        var forehead: SIMD2<Float>     // Top center (between eyebrows)
    }
    
    /// Extract key anchor points from face mesh
    private func extractAnchorPoints(from mesh: FaceMesh) -> FaceAnchors {
        // Left eye center (average of points 42-47)
        let leftEye = averagePoints(mesh.points, indices: [42, 43, 44, 45, 46, 47])
        
        // Right eye center (average of points 36-41)
        let rightEye = averagePoints(mesh.points, indices: [36, 37, 38, 39, 40, 41])
        
        // Nose tip (point 30)
        let noseTip = mesh[30]
        
        // Mouth corners (points 48 and 54)
        let leftMouth = mesh[54]
        let rightMouth = mesh[48]
        
        // Chin (point 8 - bottom of jaw)
        let chin = mesh[8]
        
        // Cheeks (jaw points 2 and 14)
        let leftCheek = mesh[14]
        let rightCheek = mesh[2]
        
        // Forehead (midpoint between eyebrows, estimated from points 21 and 22)
        let forehead = (mesh[21] + mesh[22]) * 0.5
        
        return FaceAnchors(
            leftEye: leftEye,
            rightEye: rightEye,
            noseTip: noseTip,
            leftMouth: leftMouth,
            rightMouth: rightMouth,
            chin: chin,
            leftCheek: leftCheek,
            rightCheek: rightCheek,
            forehead: forehead
        )
    }
    
    /// Average multiple points
    private func averagePoints(_ points: [SIMD2<Float>], indices: [Int]) -> SIMD2<Float> {
        var sum = SIMD2<Float>(0, 0)
        var count: Float = 0
        for i in indices {
            if i < points.count {
                sum += points[i]
                count += 1
            }
        }
        return count > 0 ? sum / count : SIMD2<Float>(0.5, 0.5)
    }
    
    /// Map a point from live face space to texture UV space
    private func mapPointToTexture(
        point: SIMD2<Float>,
        liveAnchors: FaceAnchors,
        textureAnchors: FaceAnchors,
        liveBBox: CGRect,
        textureBBox: CGRect
    ) -> SIMD2<Float> {
        // Convert point to face-relative coordinates using live bounding box
        let liveCenter = SIMD2<Float>(Float(liveBBox.midX), Float(liveBBox.midY))
        let liveSize = SIMD2<Float>(Float(liveBBox.width), Float(liveBBox.height))
        
        // Normalize point relative to live face center
        let relativePoint = (point - liveCenter) / liveSize
        
        // Find the triangular region this point falls into and use barycentric coords
        // We divide the face into regions: forehead, left eye, right eye, nose, left cheek, right cheek, mouth, chin
        
        // Determine which region based on relative position
        let textureCenter = SIMD2<Float>(Float(textureBBox.midX), Float(textureBBox.midY))
        let textureSize = SIMD2<Float>(Float(textureBBox.width), Float(textureBBox.height))
        
        // Use triangular interpolation between anchor points
        // Find closest triangle and interpolate
        
        let triangles: [(SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)] = [
            // (live1, live2, live3, tex1, tex2, tex3)
            // Forehead triangle
            (liveAnchors.forehead, liveAnchors.leftEye, liveAnchors.rightEye,
             textureAnchors.forehead, textureAnchors.leftEye, textureAnchors.rightEye),
            // Left eye to nose
            (liveAnchors.leftEye, liveAnchors.noseTip, liveAnchors.forehead,
             textureAnchors.leftEye, textureAnchors.noseTip, textureAnchors.forehead),
            // Right eye to nose
            (liveAnchors.rightEye, liveAnchors.forehead, liveAnchors.noseTip,
             textureAnchors.rightEye, textureAnchors.forehead, textureAnchors.noseTip),
            // Left cheek
            (liveAnchors.leftEye, liveAnchors.leftCheek, liveAnchors.noseTip,
             textureAnchors.leftEye, textureAnchors.leftCheek, textureAnchors.noseTip),
            // Right cheek
            (liveAnchors.rightEye, liveAnchors.noseTip, liveAnchors.rightCheek,
             textureAnchors.rightEye, textureAnchors.noseTip, textureAnchors.rightCheek),
            // Nose to mouth
            (liveAnchors.noseTip, liveAnchors.leftMouth, liveAnchors.rightMouth,
             textureAnchors.noseTip, textureAnchors.leftMouth, textureAnchors.rightMouth),
            // Left mouth to cheek
            (liveAnchors.leftCheek, liveAnchors.leftMouth, liveAnchors.noseTip,
             textureAnchors.leftCheek, textureAnchors.leftMouth, textureAnchors.noseTip),
            // Right mouth to cheek
            (liveAnchors.rightCheek, liveAnchors.noseTip, liveAnchors.rightMouth,
             textureAnchors.rightCheek, textureAnchors.noseTip, textureAnchors.rightMouth),
            // Left chin
            (liveAnchors.leftCheek, liveAnchors.chin, liveAnchors.leftMouth,
             textureAnchors.leftCheek, textureAnchors.chin, textureAnchors.leftMouth),
            // Right chin
            (liveAnchors.rightCheek, liveAnchors.rightMouth, liveAnchors.chin,
             textureAnchors.rightCheek, textureAnchors.rightMouth, textureAnchors.chin),
            // Center chin
            (liveAnchors.leftMouth, liveAnchors.chin, liveAnchors.rightMouth,
             textureAnchors.leftMouth, textureAnchors.chin, textureAnchors.rightMouth),
        ]
        
        // Find triangle containing the point and interpolate
        for (l1, l2, l3, t1, t2, t3) in triangles {
            if let bary = barycentricCoords(point: point, v1: l1, v2: l2, v3: l3) {
                // Point is inside this triangle - interpolate texture coordinates
                let textureUV = t1 * bary.x + t2 * bary.y + t3 * bary.z
                return SIMD2<Float>(
                    max(0, min(1, textureUV.x)),
                    max(0, min(1, textureUV.y))
                )
            }
        }
        
        // Fallback: simple linear mapping if point is outside all triangles
        let mappedPoint = textureCenter + relativePoint * textureSize
        return SIMD2<Float>(
            max(0, min(1, mappedPoint.x)),
            max(0, min(1, mappedPoint.y))
        )
    }
    
    /// Calculate barycentric coordinates of point in triangle
    /// Returns nil if point is outside triangle
    private func barycentricCoords(point: SIMD2<Float>, v1: SIMD2<Float>, v2: SIMD2<Float>, v3: SIMD2<Float>) -> SIMD3<Float>? {
        let v0 = v3 - v1
        let v1v = v2 - v1
        let v2v = point - v1
        
        let dot00 = simd_dot(v0, v0)
        let dot01 = simd_dot(v0, v1v)
        let dot02 = simd_dot(v0, v2v)
        let dot11 = simd_dot(v1v, v1v)
        let dot12 = simd_dot(v1v, v2v)
        
        let invDenom = 1.0 / (dot00 * dot11 - dot01 * dot01)
        let u = (dot11 * dot02 - dot01 * dot12) * invDenom
        let v = (dot00 * dot12 - dot01 * dot02) * invDenom
        let w = 1.0 - u - v
        
        // Check if point is in triangle (with small tolerance for edge cases)
        let tolerance: Float = 0.1
        if u >= -tolerance && v >= -tolerance && w >= -tolerance {
            return SIMD3<Float>(w, v, u)
        }
        return nil
    }
    
    /// Extract face mesh from tracking result
    private func extractFaceMesh(from result: FaceTrackingResult) -> FaceMesh {
        guard result.hasFace else { return .empty }
        
        // Convert landmarks to SIMD2 points
        let points = result.landmarks.map { SIMD2<Float>($0.x, $0.y) }
        
        return FaceMesh(
            points: points,
            boundingBox: result.boundingBox,
            confidence: result.confidence
        )
    }
}

// MARK: - Landmark-Based Mask Geometry

extension MaskGeometry {
    
    /// Create a face mesh geometry from detected landmarks
    static func fromLandmarks(_ mesh: FaceMesh) -> MaskGeometry {
        guard mesh.points.count >= 68 else {
            return stickerMask()
        }
        
        var vertices: [SIMD3<Float>] = []
        var uvs: [SIMD2<Float>] = []
        
        // Convert 2D landmarks to 3D vertices
        // Center around origin, scale to [-0.5, 0.5]
        let center = mesh.center
        let scale: Float = 1.0 / max(Float(mesh.boundingBox.width), 0.1)
        
        for point in mesh.points {
            let x = (point.x - center.x) * scale
            let y = (point.y - center.y) * scale
            let z: Float = 0  // Flat for now, could add depth estimation
            
            vertices.append(SIMD3<Float>(x, y, z))
            uvs.append(point)  // UV is the normalized landmark position
        }
        
        // Generate triangulation using Delaunay-like approach
        // For simplicity, use predefined triangulation for 68-point mesh
        let indices = generateFaceTriangulation()
        
        return MaskGeometry(vertices: vertices, indices: indices, uvs: uvs)
    }
    
    /// Predefined triangulation for 68-point face mesh
    private static func generateFaceTriangulation() -> [UInt16] {
        // Standard triangulation for 68-point face landmarks
        // This creates a mesh connecting the facial features
        let triangles: [(Int, Int, Int)] = [
            // Jaw to nose
            (0, 1, 36), (1, 2, 36), (2, 3, 36), (3, 4, 36),
            (4, 5, 48), (5, 6, 48), (6, 7, 48), (7, 8, 57),
            (8, 9, 57), (9, 10, 54), (10, 11, 54), (11, 12, 45),
            (12, 13, 45), (13, 14, 45), (14, 15, 45), (15, 16, 45),
            
            // Forehead/eyebrows
            (17, 18, 36), (18, 19, 36), (19, 20, 36), (20, 21, 39),
            (22, 23, 42), (23, 24, 42), (24, 25, 42), (25, 26, 45),
            
            // Eyes
            (36, 37, 38), (36, 38, 39), (39, 40, 41), (39, 41, 36),
            (42, 43, 44), (42, 44, 45), (45, 46, 47), (45, 47, 42),
            
            // Nose
            (27, 28, 31), (28, 29, 31), (29, 30, 35), (30, 33, 35),
            (31, 32, 33), (33, 34, 35),
            
            // Mouth outer
            (48, 49, 60), (49, 50, 61), (50, 51, 62), (51, 52, 63),
            (52, 53, 64), (53, 54, 65), (54, 55, 65), (55, 56, 66),
            (56, 57, 67), (57, 58, 67), (58, 59, 60), (59, 48, 60),
            
            // Mouth inner
            (60, 61, 67), (61, 62, 66), (62, 63, 66), (63, 64, 65),
            
            // Connect features
            (36, 31, 48), (45, 35, 54), (39, 27, 42), (31, 33, 51),
            (33, 35, 51), (35, 51, 52), (31, 51, 49), (31, 49, 48),
        ]
        
        var indices: [UInt16] = []
        for (a, b, c) in triangles {
            indices.append(UInt16(a))
            indices.append(UInt16(b))
            indices.append(UInt16(c))
        }
        
        return indices
    }
}
