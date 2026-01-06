//
//  FaceTrackingResult.swift
//  AnonCam
//
//  Swift face tracking result types for Vision framework
//

import simd
import CoreGraphics

// MARK: - Landmark

/// Single 3D landmark point
struct Landmark {
    var x: Float // Normalized [0, 1]
    var y: Float // Normalized [0, 1]
    var z: Float // Relative depth

    /// Convert to SIMD float3
    var simd: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

// MARK: - Head Pose

/// Head pose with 6 degrees of freedom
struct HeadPose {
    var translation: SIMD3<Float>  // tx, ty, tz
    var rotation: SIMD3<Float>     // pitch, yaw, roll in radians
    var modelMatrix: float4x4      // 4x4 transformation matrix

    static let identity = HeadPose(
        translation: .zero,
        rotation: .zero,
        modelMatrix: matrix_identity_float4x4
    )
}

// MARK: - Key Points

/// Key facial landmarks for quick access
struct KeyPoints {
    var leftEye: Landmark
    var rightEye: Landmark
    var noseTip: Landmark
    var upperLip: Landmark
    var chin: Landmark
    var leftEar: Landmark
    var rightEar: Landmark
    var forehead: Landmark

    static let empty = KeyPoints(
        leftEye: Landmark(x: 0.5, y: 0.4, z: 0),
        rightEye: Landmark(x: 0.5, y: 0.4, z: 0),
        noseTip: Landmark(x: 0.5, y: 0.5, z: 0),
        upperLip: Landmark(x: 0.5, y: 0.55, z: 0),
        chin: Landmark(x: 0.5, y: 0.65, z: 0),
        leftEar: Landmark(x: 0.35, y: 0.5, z: 0),
        rightEar: Landmark(x: 0.65, y: 0.5, z: 0),
        forehead: Landmark(x: 0.5, y: 0.35, z: 0)
    )
}

// MARK: - Face Tracking Result

/// Complete face tracking result
struct FaceTrackingResult {
    var hasFace: Bool
    var confidence: Float
    var landmarks: [Landmark]
    var pose: HeadPose
    var keyPoints: KeyPoints
    var boundingBox: CGRect // Normalized [0,1]

    static let empty = FaceTrackingResult(
        hasFace: false,
        confidence: 0,
        landmarks: [],
        pose: .identity,
        keyPoints: .empty,
        boundingBox: .zero
    )
}

// MARK: - Mask Geometry

/// 3D mask that sits over the face
struct MaskGeometry {
    let vertices: [SIMD3<Float>]
    let indices: [UInt16]
    let uvs: [SIMD2<Float>]

    /// Simple ellipsoid mask facing +Z (toward camera)
    static func helmetMask(segmentCount: Int = 32, ringCount: Int = 16) -> MaskGeometry {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt16] = []
        var uvs: [SIMD2<Float>] = []
        
        // Generate sphere vertices
        for ring in 0...ringCount {
            let phi = Float(ring) / Float(ringCount) * Float.pi * 0.5 // 0 to pi/2 (hemisphere)
            let y = cos(phi)
            let r = sin(phi)
            
            for seg in 0...segmentCount {
                let theta = Float(seg) / Float(segmentCount) * Float.pi * 2.0
                let x = r * cos(theta)
                let z = r * sin(theta)
                
                vertices.append(SIMD3<Float>(x * 0.5, y * 0.6, z * 0.4))
                uvs.append(SIMD2<Float>(Float(seg) / Float(segmentCount), Float(ring) / Float(ringCount)))
            }
        }
        
        // Generate indices
        let vertsPerRing = segmentCount + 1
        for ring in 0..<ringCount {
            for seg in 0..<segmentCount {
                let curr = ring * vertsPerRing + seg
                let next = curr + vertsPerRing
                
                indices.append(UInt16(curr))
                indices.append(UInt16(next))
                indices.append(UInt16(curr + 1))
                
                indices.append(UInt16(curr + 1))
                indices.append(UInt16(next))
                indices.append(UInt16(next + 1))
            }
        }
        
        return MaskGeometry(vertices: vertices, indices: indices, uvs: uvs)
    }

    /// Oval face mask
    static func organicMask() -> MaskGeometry {
        return helmetMask(segmentCount: 24, ringCount: 12)
    }

    /// Low poly version
    static func lowPolyMask() -> MaskGeometry {
        return helmetMask(segmentCount: 8, ringCount: 4)
    }
    
    /// Flat circle
    static func circleMask(segments: Int = 32) -> MaskGeometry {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt16] = []
        var uvs: [SIMD2<Float>] = []
        
        // Center
        vertices.append(SIMD3<Float>(0, 0, 0))
        uvs.append(SIMD2<Float>(0.5, 0.5))
        
        // Ring - flip U coordinate to correct horizontal flip
        for i in 0...segments {
            let angle = Float(i) / Float(segments) * Float.pi * 2.0
            vertices.append(SIMD3<Float>(cos(angle) * 0.5, sin(angle) * 0.5, 0))
            uvs.append(SIMD2<Float>(1.0 - (cos(angle) + 1) * 0.5, (sin(angle) + 1) * 0.5))
        }
        
        // Fan triangles
        for i in 0..<segments {
            indices.append(0)
            indices.append(UInt16(i + 1))
            indices.append(UInt16(i + 2))
        }
        
        return MaskGeometry(vertices: vertices, indices: indices, uvs: uvs)
    }
    
    /// Flat quad for stickers
    static func stickerMask() -> MaskGeometry {
        let vertices: [SIMD3<Float>] = [
            SIMD3<Float>(-0.5, -0.5, 0),
            SIMD3<Float>( 0.5, -0.5, 0),
            SIMD3<Float>( 0.5,  0.5, 0),
            SIMD3<Float>(-0.5,  0.5, 0)
        ]
        let indices: [UInt16] = [0, 1, 2, 0, 2, 3]
        // Flip V coordinate to correct vertical flip
        let uvs: [SIMD2<Float>] = [
            SIMD2<Float>(0, 0),  // bottom-left vertex -> top-left UV
            SIMD2<Float>(1, 0),  // bottom-right vertex -> top-right UV
            SIMD2<Float>(1, 1),  // top-right vertex -> bottom-right UV
            SIMD2<Float>(0, 1)   // top-left vertex -> bottom-left UV
        ]
        return MaskGeometry(vertices: vertices, indices: indices, uvs: uvs)
    }
}
