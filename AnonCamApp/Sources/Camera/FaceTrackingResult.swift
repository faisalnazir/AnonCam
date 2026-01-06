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
    /// Vertex positions for the mask mesh (local space)
    let vertices: [SIMD3<Float>]

    /// Triangle indices
    let indices: [UInt16]

    /// UV coordinates for texturing
    let uvs: [SIMD2<Float>]

    /// Create a simple helmet/mask geometry
    static func helmetMask(segmentCount: Int = 24, heightSegments: Int = 12) -> MaskGeometry {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt16] = []
        var uvs: [SIMD2<Float>] = []

        let radius: Float = 0.35
        let height: Float = 0.45

        // Generate vertices (hemisphere + extended neck)
        for y in 0...heightSegments {
            let v = Float(y) / Float(heightSegments)
            let yAngle = v * .pi / 2.2  // Slightly more than 90 degrees for neck coverage
            let yPos = cos(yAngle) * height - height * 0.25
            let ringRadius = sin(yAngle) * radius

            for x in 0..<segmentCount {
                let u = Float(x) / Float(segmentCount)
                let xAngle = u * 2 * .pi

                let xPos = cos(xAngle) * ringRadius
                let zPos = sin(xAngle) * ringRadius

                vertices.append(SIMD3<Float>(xPos, yPos, zPos))
                uvs.append(SIMD2<Float>(u, v))
            }
        }

        // Generate indices
        for y in 0..<heightSegments {
            for x in 0..<segmentCount {
                let nextX = (x + 1) % segmentCount

                let i0 = UInt16(y * segmentCount + x)
                let i1 = UInt16(y * segmentCount + nextX)
                let i2 = UInt16((y + 1) * segmentCount + x)
                let i3 = UInt16((y + 1) * segmentCount + nextX)

                // Two triangles per quad
                indices.append(contentsOf: [i0, i2, i1])
                indices.append(contentsOf: [i1, i2, i3])
            }
        }

        return MaskGeometry(vertices: vertices, indices: indices, uvs: uvs)
    }

    /// Create a more organic face-shaped mask
    static func organicMask() -> MaskGeometry {
        // Create mask based on average face proportions
        var vertices: [SIMD3<Float>] = []

        // Front face (8x8 grid)
        let faceWidth: Float = 0.4
        let faceHeight: Float = 0.5
        let faceDepth: Float = 0.2

        let rows = 10
        let cols = 12

        for y in 0...rows {
            let v = Float(y) / Float(rows)
            let yPos = (v - 0.5) * faceHeight

            for x in 0...cols {
                let u = Float(x) / Float(cols)
                let xPos = (u - 0.5) * faceWidth

                // Curve outward for face depth
                let angleX = u * .pi - .pi / 2
                let angleY = v * .pi - .pi / 2
                let zPos = sin(angleX) * sin(angleY) * faceDepth

                vertices.append(SIMD3<Float>(xPos, yPos, zPos + faceDepth))
            }
        }

        // Generate indices
        var indices: [UInt16] = []
        for y in 0..<rows {
            for x in 0..<cols {
                let i0 = UInt16(y * (cols + 1) + x)
                let i1 = UInt16(y * (cols + 1) + x + 1)
                let i2 = UInt16((y + 1) * (cols + 1) + x)
                let i3 = UInt16((y + 1) * (cols + 1) + x + 1)

                indices.append(contentsOf: [i0, i2, i1])
                indices.append(contentsOf: [i1, i2, i3])
            }
        }

        // Generate UVs
        var uvs: [SIMD2<Float>] = []
        for y in 0...rows {
            let v = Float(y) / Float(rows)
            for x in 0...cols {
                let u = Float(x) / Float(cols)
                uvs.append(SIMD2<Float>(u, v))
            }
        }

        return MaskGeometry(vertices: vertices, indices: indices, uvs: uvs)
    }

    /// Create a stylized low-poly mask
    static func lowPolyMask() -> MaskGeometry {
        return helmetMask(segmentCount: 8, heightSegments: 6)
    }
    
    /// Create a flat circular mask (disc)
    static func circleMask(segments: Int = 32) -> MaskGeometry {
        var vertices: [SIMD3<Float>] = []
        var indices: [UInt16] = []
        var uvs: [SIMD2<Float>] = []
        
        let radius: Float = 0.4
        
        // Center vertex
        vertices.append(SIMD3<Float>(0, 0, 0.1))
        uvs.append(SIMD2<Float>(0.5, 0.5))
        
        // Ring vertices
        for i in 0..<segments {
            let angle = Float(i) / Float(segments) * 2 * .pi
            let x = cos(angle) * radius
            let y = sin(angle) * radius
            vertices.append(SIMD3<Float>(x, y, 0.1))
            uvs.append(SIMD2<Float>(
                (cos(angle) + 1) / 2,
                (sin(angle) + 1) / 2
            ))
        }
        
        // Triangle fan from center
        for i in 0..<segments {
            let nextI = (i + 1) % segments
            indices.append(0)  // Center
            indices.append(UInt16(i + 1))
            indices.append(UInt16(nextI + 1))
        }
        
        return MaskGeometry(vertices: vertices, indices: indices, uvs: uvs)
    }
}
