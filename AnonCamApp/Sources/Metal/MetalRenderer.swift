//
//  MetalRenderer.swift
//  AnonCam
//
//  Metal renderer for compositing camera feed with face mask
//

import AppKit
import CoreMedia
import CoreVideo
import Foundation
import Metal
import MetalKit
import simd

// MARK: - Renderer Delegate

protocol MetalRendererDelegate: AnyObject {
    func renderer(_ renderer: MetalRenderer, didOutput pixelBuffer: CVPixelBuffer, at time: CMTime)
}

// MARK: - Metal Renderer

/// Renders camera feed with face mask overlay using Metal
final class MetalRenderer: @unchecked Sendable {

    // MARK: - Properties

    weak var delegate: (any MetalRendererDelegate)?

    private(set) var device: any MTLDevice
    private let commandQueue: any MTLCommandQueue

    // Textures
    private var cameraTexture: (any MTLTexture)?
    private var outputTexture: (any MTLTexture)?
    private var depthTexture: (any MTLTexture)?

    // Texture cache for CVPixelBuffer conversion
    private var textureCache: CVMetalTextureCache?

    // Pipeline states
    private var quadPipelineState: (any MTLRenderPipelineState)?
    private var maskPipelineState: (any MTLRenderPipelineState)?
    private var samplerState: (any MTLSamplerState)?
    private var quadDepthState: (any MTLDepthStencilState)?
    private var maskDepthState: (any MTLDepthStencilState)?

    // Buffers
    private var quadVertexBuffer: (any MTLBuffer)?
    private var quadUniformBuffer: (any MTLBuffer)?
    private var maskVertexBuffer: (any MTLBuffer)?
    private var maskIndexBuffer: (any MTLBuffer)?
    private var maskUniformBuffer: (any MTLBuffer)?

    // Geometry
    private var maskIndexCount: Int = 0
    var maskGeometry = MaskGeometry.helmetMask() {
        didSet {
            updateMaskGeometry()
        }
    }

    // Output
    private var pixelBufferPool: CVPixelBufferPool?
    private var outputWidth: Int = 1920
    private var outputHeight: Int = 1080

    // Mask settings
    var maskColor: SIMD4<Float> = SIMD4<Float>(0.2, 0.25, 0.3, 1.0) // Slate blue-gray
    var maskRoughness: Float = 0.7
    var maskMetallic: Float = 0.0
    
    // Texture overlay
    var maskTexture: (any MTLTexture)?
    
    // Rendering Options
    var isPixelationEnabled: Bool = true
    var is3DMaskEnabled: Bool = false
    var isStickerMode: Bool = false // Simple 2D quad overlay
    var isDebugEnabled: Bool = false  // Show face detection debug info

    private var startTime: CFTimeInterval = 0

    // MARK: - Mask Uniforms

    struct MaskUniforms {
        var modelMatrix: simd_float4x4 = matrix_identity_float4x4
        var viewProjectionMatrix: simd_float4x4 = matrix_identity_float4x4
        var baseColor: simd_float4 = SIMD4<Float>(0.2, 0.25, 0.3, 1.0)
        var roughness: Float = 0.7
        var metallic: Float = 0.0
        var time: Float = 0
        var hasFace: Int32 = 0
        var hasTexture: Int32 = 0  // Flag for texture overlay
        var isStickerMode: Int32 = 0 // Flag for 2D sticker mode
    }

    struct QuadUniforms {
        var faceRect: SIMD4<Float>
        var hasFace: Int32
        var pixelSize: Float
        var debugMode: Int32  // 1 = show bounding box
        var orientMatrix: simd_float4x4 // 3D rotation of the head
    }

    /// Vertex data structure for mask mesh
    private struct MaskVertexData {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var texCoord: SIMD2<Float>
    }

    // MARK: - Initialization

    init?(device: any MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue
        self.startTime = CACurrentMediaTime()

        setupTextureCache()
        setupPipelines()
        setupBuffers()
    }

    // MARK: - Setup

    private func setupTextureCache() {
        let result = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )

        if result != kCVReturnSuccess {
            print("Failed to create Metal texture cache")
        }
    }

    /// Load Metal library - tries default library first, then compiles from source
    private func loadMetalLibrary() -> (any MTLLibrary)? {
        // Try default library first (works with Xcode builds)
        if let library = device.makeDefaultLibrary() {
            print("Using default Metal library")
            return library
        }
        
        print("Default library not available, compiling shaders from source...")
        
        // Embedded shader source for SPM builds
        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;
        
        // Vertex input for camera quad
        struct QuadVertex {
            float2 position [[attribute(0)]];
            float2 texCoord [[attribute(1)]];
        };
        
        // Vertex input for 3D mask mesh
        struct MaskVertex {
            float3 position [[attribute(0)]];
            float3 normal [[attribute(1)]];
            float2 texCoord [[attribute(2)]];
        };
        
        // Uniforms for mask transform
        struct MaskUniforms {
            float4x4 modelMatrix;
            float4x4 viewProjectionMatrix;
            float4 baseColor;
            float roughness;
            float metallic;
            float time;
            int hasFace;
            int hasTexture;  // Flag for texture overlay
            int isStickerMode;
        };
        
        // Uniforms for camera background effects (Pixelation)
        struct QuadUniforms {
            float4 faceRect;
            int hasFace;
            float pixelSize;
            int debugMode;
            float4x4 orientMatrix;
        };

        struct QuadFragmentIn {
            float4 position [[position]];
            float2 texCoord;
        };
        
        struct MaskFragmentIn {
            float4 position [[position]];
            float3 worldPos;
            float3 normal;
            float2 texCoord;
            float3 viewDir;
        };
        
        // Camera background shaders
        vertex QuadFragmentIn quadVertexShader(QuadVertex in [[stage_in]]) {
            QuadFragmentIn out;
            out.position = float4(in.position, 1.0, 1.0);
            out.texCoord = in.texCoord;
            return out;
        }
        
        // Helper to compute distance from point 'p' to line segment 'ab'
        float distToSegment(float2 p, float2 a, float2 b) {
            float2 pa = p - a, ba = b - a;
            float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            return length(pa - ba * h);
        }

        fragment float4 quadFragmentShader(
            QuadFragmentIn in [[stage_in]],
            texture2d<float> cameraTexture [[texture(0)]],
            sampler textureSampler [[sampler(0)]],
            constant QuadUniforms &uniforms [[buffer(0)]]
        ) {
            float2 uv = in.texCoord;
            bool isInFace = false;
            
            if (uniforms.hasFace == 1) {
                float4 r = uniforms.faceRect;
                if (uv.x >= r.x && uv.x <= r.x + r.z &&
                    uv.y >= r.y && uv.y <= r.y + r.w) {
                    isInFace = true;
                    
                    if (uniforms.pixelSize > 0.001) {
                        float pSize = uniforms.pixelSize;
                        uv = floor(uv / pSize) * pSize + pSize * 0.5;
                    }
                }
            }
            
            float4 color = cameraTexture.sample(textureSampler, uv);
            
            // Draw debug overlays
            if (uniforms.debugMode == 1 && uniforms.hasFace == 1) {
                float4 r = uniforms.faceRect;
                float border = 0.003; // Border thickness
                
                // 1. Draw Bounding Box Outline
                bool onEdge = (abs(in.texCoord.x - r.x) < border && in.texCoord.y >= r.y && in.texCoord.y <= r.y + r.w) ||
                              (abs(in.texCoord.x - (r.x + r.z)) < border && in.texCoord.y >= r.y && in.texCoord.y <= r.y + r.w) ||
                              (abs(in.texCoord.y - r.y) < border && in.texCoord.x >= r.x && in.texCoord.x <= r.x + r.z) ||
                              (abs(in.texCoord.y - (r.y + r.w)) < border && in.texCoord.x >= r.x && in.texCoord.x <= r.x + r.z);
                
                if (onEdge) {
                    return float4(0.0, 1.0, 0.0, 1.0); // Bright green border
                }

                // 2. Draw 3D Axes
                // Center in NDC [-1, 1], then flip Y to match UV [0, 1]
                float2 faceCenterUV = float2(r.x + r.z * 0.5, r.y + r.w * 0.5);
                
                // Axis length relative to face size
                float axisLen = r.z * 0.5;
                
                // Unit vectors for axes
                float4 axisX = uniforms.orientMatrix * float4(1, 0, 0, 0);
                float4 axisY = uniforms.orientMatrix * float4(0, 1, 0, 0);
                float4 axisZ = uniforms.orientMatrix * float4(0, 0, 1, 0);
                
                // Project to 2D UV space
                // Vision Y is bottom-up, our UV is top-down (flipping Y component of axis)
                float2 pX = faceCenterUV + float2(axisX.x, -axisX.y) * axisLen;
                float2 pY = faceCenterUV + float2(axisY.x, -axisY.y) * axisLen;
                float2 pZ = faceCenterUV + float2(axisZ.x, -axisZ.y) * axisLen;
                
                float lineThick = 0.002;
                if (distToSegment(in.texCoord, faceCenterUV, pX) < lineThick) return float4(1, 0, 0, 1); // X = Red
                if (distToSegment(in.texCoord, faceCenterUV, pY) < lineThick) return float4(0, 1, 0, 1); // Y = Green
                if (distToSegment(in.texCoord, faceCenterUV, pZ) < lineThick) return float4(0, 0, 1, 1); // Z = Blue
                
                // Dim the rest of the image slightly to make overlays pop
                if (!isInFace) {
                    color.rgb *= 0.5;
                }
            }
            
            color.rgb = pow(color.rgb, float3(0.95));
            color.rgb = saturate(color.rgb);
            return color;
        }
        
        // Face mask shaders
        vertex MaskFragmentIn maskVertexShader(
            MaskVertex in [[stage_in]],
            constant MaskUniforms &uniforms [[buffer(0)]]
        ) {
            MaskFragmentIn out;
            float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
            out.worldPos = worldPos.xyz;
            float4 viewPos = uniforms.viewProjectionMatrix * worldPos;
            out.position = viewPos;
            float3x3 normalMatrix = float3x3(uniforms.modelMatrix[0].xyz,
                                             uniforms.modelMatrix[1].xyz,
                                             uniforms.modelMatrix[2].xyz);
            out.normal = normalize(normalMatrix * in.normal);
            out.texCoord = in.texCoord;
            out.viewDir = normalize(-worldPos.xyz);
            return out;
        }
        
        fragment float4 maskFragmentShader(
            MaskFragmentIn in [[stage_in]],
            constant MaskUniforms &uniforms [[buffer(0)]],
            texture2d<float> maskTexture [[texture(0)]]
        ) {
            if (uniforms.hasFace == 0) {
                return float4(0.0);
            }
            float3 N = normalize(in.normal);
            float3 V = normalize(in.viewDir);
            float3 lightDir1 = normalize(float3(1.0, 1.0, 1.0));
            float3 lightDir2 = normalize(float3(-0.5, 0.5, -1.0));
            float NdotL1 = max(0.0, dot(N, lightDir1));
            float NdotL2 = max(0.0, dot(N, lightDir2));
            float rim = 1.0 - max(0.0, dot(N, V));
            rim = pow(rim, 3.0);
            float3 baseColor = uniforms.baseColor.rgb;
            
            // Sample texture if available
            if (uniforms.hasTexture == 1) {
                constexpr sampler texSampler(filter::linear, address::repeat);
                float4 texColor = maskTexture.sample(texSampler, in.texCoord);
                baseColor = mix(baseColor, texColor.rgb, texColor.a);
            }
            
            float3 litColor;
            if (uniforms.isStickerMode == 1) {
                litColor = baseColor; // No shading for stickers
            } else {
                float3 litColorShaded = baseColor * (0.4 + 0.4 * NdotL1 + 0.2 * NdotL2);
                litColorShaded += rim * 0.15 * float3(1.0, 1.0, 1.0);
                float pattern = sin(in.worldPos.x * 20.0 + uniforms.time) *
                                cos(in.worldPos.y * 20.0 + uniforms.time * 0.7);
                litColorShaded += pattern * 0.02;
                litColor = litColorShaded;
            }
            float alpha = uniforms.baseColor.a;
            return float4(litColor, alpha);
        }
        """
        
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            print("Shaders compiled successfully from source")
            return library
        } catch {
            print("CRITICAL: Failed to compile shaders from source: \(error)")
            return nil
        }
    }

    private func setupPipelines() {
        guard let library = loadMetalLibrary() else {
            print("CRITICAL: Failed to create Metal library - rendering will not work!")
            return
        }
        print("Metal library loaded successfully")

        // Quad pipeline for camera background
        let quadDescriptor = MTLRenderPipelineDescriptor()
        quadDescriptor.vertexFunction = library.makeFunction(name: "quadVertexShader")
        quadDescriptor.fragmentFunction = library.makeFunction(name: "quadFragmentShader")
        quadDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        quadDescriptor.depthAttachmentPixelFormat = .depth32Float

        // Quad vertex descriptor: position (float2) + texCoord (float2)
        let quadVertexDescriptor = MTLVertexDescriptor()
        // Position attribute
        quadVertexDescriptor.attributes[0].format = .float2
        quadVertexDescriptor.attributes[0].offset = 0
        quadVertexDescriptor.attributes[0].bufferIndex = 0
        // TexCoord attribute
        quadVertexDescriptor.attributes[1].format = .float2
        quadVertexDescriptor.attributes[1].offset = MemoryLayout<Float>.stride * 2
        quadVertexDescriptor.attributes[1].bufferIndex = 0
        // Buffer layout
        quadVertexDescriptor.layouts[0].stride = MemoryLayout<Float>.stride * 4
        quadVertexDescriptor.layouts[0].stepFunction = .perVertex

        quadDescriptor.vertexDescriptor = quadVertexDescriptor

        do {
            quadPipelineState = try device.makeRenderPipelineState(descriptor: quadDescriptor)
            print("Quad pipeline state created successfully")
        } catch {
            print("CRITICAL: Failed to create quad pipeline: \(error)")
        }

        // Mask pipeline for 3D geometry
        let maskDescriptor = MTLRenderPipelineDescriptor()
        maskDescriptor.vertexFunction = library.makeFunction(name: "maskVertexShader")
        maskDescriptor.fragmentFunction = library.makeFunction(name: "maskFragmentShader")
        maskDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        maskDescriptor.depthAttachmentPixelFormat = .depth32Float

        // Alpha blending for mask
        maskDescriptor.colorAttachments[0].isBlendingEnabled = true
        maskDescriptor.colorAttachments[0].rgbBlendOperation = .add
        maskDescriptor.colorAttachments[0].alphaBlendOperation = .add
        maskDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        maskDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        maskDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        maskDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .zero

        // Vertex descriptor - Packed Float array (8 floats per vertex = 32 bytes)
        // pos(3) + normal(3) + uv(2)
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.attributes[0].format = .float3
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0

        vertexDescriptor.attributes[1].format = .float3
        vertexDescriptor.attributes[1].offset = 12 // 3 * 4 bytes
        vertexDescriptor.attributes[1].bufferIndex = 0

        vertexDescriptor.attributes[2].format = .float2
        vertexDescriptor.attributes[2].offset = 24 // 6 * 4 bytes
        vertexDescriptor.attributes[2].bufferIndex = 0

        vertexDescriptor.layouts[0].stride = 32
        vertexDescriptor.layouts[0].stepFunction = .perVertex

        maskDescriptor.vertexDescriptor = vertexDescriptor

        do {
            maskPipelineState = try device.makeRenderPipelineState(descriptor: maskDescriptor)
            print("Mask pipeline state created successfully")
        } catch {
            print("CRITICAL: Failed to create mask pipeline: \(error)")
        }

        // Depth Stencil States

        // 1. Quad: No depth write (background)
        let quadDepthDescriptor = MTLDepthStencilDescriptor()
        quadDepthDescriptor.isDepthWriteEnabled = false
        quadDepthDescriptor.depthCompareFunction = .always
        quadDepthState = device.makeDepthStencilState(descriptor: quadDepthDescriptor)

        // 2. Mask: Depth write enabled (3D geometry)
        let maskDepthDescriptor = MTLDepthStencilDescriptor()
        maskDepthDescriptor.isDepthWriteEnabled = true
        maskDepthDescriptor.depthCompareFunction = .less
        maskDepthState = device.makeDepthStencilState(descriptor: maskDepthDescriptor)
    }

    private func setupBuffers() {
        // Quad vertices: position (x, y) + texCoord (u, v)
        let quadVertices: [Float] = [
            -1.0, -1.0, 0.0, 1.0,
             1.0, -1.0, 1.0, 1.0,
            -1.0,  1.0, 0.0, 0.0,
             1.0,  1.0, 1.0, 0.0
        ]
        quadVertexBuffer = device.makeBuffer(bytes: quadVertices,
                                            length: quadVertices.count * MemoryLayout<Float>.stride,
                                            options: [])

        // Build mask vertex data
        // Build mask vertex data as explicit Float array to avoid alignment issues
        var maskFloatData: [Float] = []
        maskFloatData.reserveCapacity(maskGeometry.vertices.count * 8)
        
        for (i, vertex) in maskGeometry.vertices.enumerated() {
            let normal = normalize(vertex)
            let uv = i < maskGeometry.uvs.count ? maskGeometry.uvs[i] : SIMD2<Float>(0, 0)
            
            // Position
            maskFloatData.append(vertex.x)
            maskFloatData.append(vertex.y)
            maskFloatData.append(vertex.z)
            
            // Normal
            maskFloatData.append(normal.x)
            maskFloatData.append(normal.y)
            maskFloatData.append(normal.z)
            
            // UV
            maskFloatData.append(uv.x)
            maskFloatData.append(uv.y)
        }

        maskVertexBuffer = device.makeBuffer(bytes: maskFloatData,
                                            length: maskFloatData.count * MemoryLayout<Float>.stride,
                                            options: [])

        maskIndexCount = maskGeometry.indices.count
        maskIndexBuffer = device.makeBuffer(bytes: maskGeometry.indices,
                                          length: maskGeometry.indices.count * MemoryLayout<UInt16>.stride,
                                          options: [])

        maskUniformBuffer = device.makeBuffer(length: MemoryLayout<MaskUniforms>.stride, options: [])
        quadUniformBuffer = device.makeBuffer(length: MemoryLayout<QuadUniforms>.stride, options: [])


        setupOutputTextures()
    }

    private func updateMaskGeometry() {
        var maskVertices: [MaskVertexData] = []
        for i in 0..<maskGeometry.vertices.count {
            let vertex = maskGeometry.vertices[i]
            let uv = i < maskGeometry.uvs.count ? maskGeometry.uvs[i] : SIMD2<Float>(0, 0)
            
            // For sticker mode or flat masks, we want a forward-facing normal
            // For 3D masks, we use the vertex position as a proxy for the sphere-like normal
            var normal = normalize(vertex)
            if normal.x.isNaN || normal.y.isNaN || normal.z.isNaN || length(vertex) < 0.0001 {
                normal = SIMD3<Float>(0, 0, 1)
            }
            
            maskVertices.append(MaskVertexData(
                position: vertex,
                normal: normal,
                texCoord: uv
            ))
        }

        maskVertexBuffer = device.makeBuffer(bytes: maskVertices,
                                            length: maskVertices.count * MemoryLayout<MaskVertexData>.stride,
                                            options: [])

        maskIndexCount = maskGeometry.indices.count
        maskIndexBuffer = device.makeBuffer(bytes: maskGeometry.indices,
                                          length: maskGeometry.indices.count * MemoryLayout<UInt16>.stride,
                                          options: [])
    }

    private func setupOutputTextures() {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        // Use .shared storage for macOS to allow CPU access for exporting
        #if os(macOS)
        textureDescriptor.storageMode = .managed
        #else
        textureDescriptor.storageMode = .shared
        #endif

        outputTexture = device.makeTexture(descriptor: textureDescriptor)

        // Depth texture
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        depthTexture = device.makeTexture(descriptor: depthDescriptor)

        // Pixel buffer pool
        let poolAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]

        CVPixelBufferPoolCreate(nil, nil, poolAttributes as CFDictionary, &pixelBufferPool)
    }

    func setOutputSize(width: Int, height: Int) {
        guard width != outputWidth || height != outputHeight else { return }
        outputWidth = width
        outputHeight = height
        setupOutputTextures()
    }

    // MARK: - Rendering

    func render(cameraPixelBuffer: CVPixelBuffer, faceResult: FaceTrackingResult, at time: CMTime) {
        // Convert camera pixel buffer to Metal texture
        guard let texture = makeTexture(from: cameraPixelBuffer) else {
            return
        }
        cameraTexture = texture

        // Update output size if needed
        let width = CVPixelBufferGetWidth(cameraPixelBuffer)
        let height = CVPixelBufferGetHeight(cameraPixelBuffer)
        if width != outputWidth || height != outputHeight {
            setOutputSize(width: width, height: height)
        }

        // Render frame
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let outputTexture = outputTexture,
              let depthTexture = depthTexture else {
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = outputTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        renderPassDescriptor.depthAttachment.texture = depthTexture
        renderPassDescriptor.depthAttachment.loadAction = .clear
        renderPassDescriptor.depthAttachment.storeAction = .store
        renderPassDescriptor.depthAttachment.clearDepth = 1.0

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        // Create sampler if needed
        if samplerState == nil {
            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.sAddressMode = .clampToEdge
            samplerDescriptor.tAddressMode = .clampToEdge
            samplerState = device.makeSamplerState(descriptor: samplerDescriptor)
        }

        // Draw camera background first (No depth write)
        if let quadPipeline = quadPipelineState,
           let quadBuffer = quadVertexBuffer,
           let cameraTexture = cameraTexture,
           let sampler = samplerState,
           let depthState = quadDepthState,
           let quadUniformBuffer = quadUniformBuffer {
            
            // Update Quad Uniforms
            var quadUniforms = QuadUniforms(
                faceRect: SIMD4<Float>(
                    Float(faceResult.boundingBox.origin.x),
                    Float(faceResult.boundingBox.origin.y),
                    Float(faceResult.boundingBox.width),
                    Float(faceResult.boundingBox.height)
                ),
                hasFace: faceResult.hasFace ? 1 : 0,
                pixelSize: isPixelationEnabled ? 0.03 : 0,
                debugMode: isDebugEnabled ? 1 : 0,
                orientMatrix: faceResult.pose.modelMatrix
            )
            memcpy(quadUniformBuffer.contents(), &quadUniforms, MemoryLayout<QuadUniforms>.stride)

            renderEncoder.setRenderPipelineState(quadPipeline)
            renderEncoder.setDepthStencilState(depthState)
            renderEncoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
            renderEncoder.setFragmentTexture(cameraTexture, index: 0)
            renderEncoder.setFragmentSamplerState(sampler, index: 0)
            renderEncoder.setFragmentBuffer(quadUniformBuffer, offset: 0, index: 0)
            renderEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // Then draw face mask (With depth write)
        if faceResult.hasFace && is3DMaskEnabled,
           let maskPipeline = maskPipelineState,
           let vertexBuffer = maskVertexBuffer,
           let indexBuffer = maskIndexBuffer,
           let uniformBuffer = maskUniformBuffer,
           let depthState = maskDepthState {

            renderEncoder.setRenderPipelineState(maskPipeline)
            renderEncoder.setDepthStencilState(depthState)

            // Update uniforms
            var uniforms = updateUniforms(from: faceResult)
            uniforms.isStickerMode = isStickerMode ? 1 : 0
            
            // Set texture flag if we have a mask texture
            if let texture = maskTexture {
                uniforms.hasTexture = 1
                renderEncoder.setFragmentTexture(texture, index: 0)
            } else {
                uniforms.hasTexture = 0
            }
            
            memcpy(uniformBuffer.contents(), &uniforms, MemoryLayout<MaskUniforms>.stride)
            renderEncoder.setVertexBuffer(uniformBuffer, offset: 0, index: 0)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 1)
            renderEncoder.setFragmentBuffer(uniformBuffer, offset: 0, index: 0)

            renderEncoder.drawIndexedPrimitives(type: .triangle,
                                              indexCount: maskIndexCount,
                                              indexType: .uint16,
                                              indexBuffer: indexBuffer,
                                              indexBufferOffset: 0)
        }

        renderEncoder.endEncoding()

        // Synchronize managed texture for CPU read
        #if os(macOS)
        let currentOutputTexture = self.outputTexture
        if let texture = currentOutputTexture, 
           texture.storageMode == .managed,
           let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.synchronize(resource: texture)
            blitEncoder.endEncoding()
        }
        #endif

        // Get output
        commandBuffer.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.exportOutputTexture(at: time)
        }

        commandBuffer.commit()
    }

    private func matrix_perspective_right_hand(fovyRadians: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> simd_float4x4 {
        let ys = 1.0 / tanf(fovyRadians * 0.5)
        let xs = ys / aspectRatio
        let zs = farZ / (nearZ - farZ)
        
        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4<Float>(xs,  0,  0,   0)
        matrix.columns.1 = SIMD4<Float>(0,  ys,  0,   0)
        matrix.columns.2 = SIMD4<Float>(0,   0, zs,  -1)
        matrix.columns.3 = SIMD4<Float>(0,   0, zs * nearZ, 0)
        return matrix
    }

    private func updateUniforms(from faceResult: FaceTrackingResult) -> MaskUniforms {
        var uniforms = MaskUniforms()

        uniforms.hasFace = faceResult.hasFace ? 1 : 0
        uniforms.baseColor = maskColor
        uniforms.roughness = maskRoughness
        uniforms.metallic = maskMetallic
        uniforms.time = Float(CACurrentMediaTime() - startTime)

        let aspect = Float(outputWidth) / Float(outputHeight)

        if faceResult.hasFace {
            if isStickerMode {
                // SIMPLE 2D STICKER MODE: Map directly to bounding box
                let bbox = faceResult.boundingBox
                
                // NDC center
                let centerX = Float(bbox.midX) * 2.0 - 1.0
                let centerY = Float(bbox.midY) * 2.0 - 1.0
                
                // NDC dimension
                let ndcW = Float(bbox.width) * 2.0
                let ndcH = Float(bbox.height) * 2.0
                
                var translationMatrix = matrix_identity_float4x4
                translationMatrix.columns.3 = SIMD4<Float>(centerX, centerY, 0.5, 1.0)
                
                // Scale: Dimensions in NDC
                var scaleMatrix = matrix_identity_float4x4
                scaleMatrix[0][0] = ndcW
                scaleMatrix[1][1] = ndcH
                scaleMatrix[2][2] = 1.0
                
                // No rotation for sticker mode (keeps it aligned to camera)
                uniforms.modelMatrix = translationMatrix * scaleMatrix
                
                // Simple orthogonal projection
                var projection = matrix_identity_float4x4
                projection[2][2] = -0.5
                projection[3][2] = 0.5
                uniforms.viewProjectionMatrix = projection
                
            } else {
                // PERSPECTIVE 3D MODE
                // Get face center and size from bounding box (normalized [0,1])
                let bbox = faceResult.boundingBox
                let faceWidth = Float(bbox.width)
                
                // Face center in normalized coordinates [0,1]
                let faceCenterX = Float(bbox.midX)
                let faceCenterY = Float(bbox.midY)
                
                // Convert to NDC [-1, 1] for translation base
                let ndcX = faceCenterX * 2.0 - 1.0
                let ndcY = faceCenterY * 2.0 - 1.0 // NO FLIP (Vision and NDC are both bottom-up)
                
                // Perspective Setup
                let fov = 45.0 * Float.pi / 180.0
                let tanHalfFov = tan(fov * 0.5)
                
                // Calculate distance based on face width relative to screen
                let distance = 1.0 / (faceWidth * tanHalfFov * 1.5)
                
                // Place mask in 3D space
                let worldX = ndcX * distance * aspect * tanHalfFov
                let worldY = ndcY * distance * tanHalfFov
                let worldZ = -distance
                
                let headScale: Float = 1.33
                
                var scaleMatrix = matrix_identity_float4x4
                scaleMatrix[0][0] = headScale
                scaleMatrix[1][1] = headScale
                scaleMatrix[2][2] = headScale
                
                let rotationMatrix = faceResult.pose.modelMatrix
                
                var translationMatrix = matrix_identity_float4x4
                translationMatrix.columns.3 = SIMD4<Float>(worldX, worldY, worldZ, 1.0)
                
                uniforms.modelMatrix = translationMatrix * rotationMatrix * scaleMatrix
                
                uniforms.viewProjectionMatrix = matrix_perspective_right_hand(
                    fovyRadians: fov,
                    aspectRatio: aspect,
                    nearZ: 0.1,
                    farZ: 100.0
                )
            }
        } else {
            uniforms.modelMatrix = matrix_identity_float4x4
            uniforms.viewProjectionMatrix = matrix_identity_float4x4
        }

        return uniforms
    }

    // MARK: - CVPixelBuffer to MTLTexture conversion

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> (any MTLTexture)? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let textureCache = textureCache else {
            return nil
        }

        // IMPORTANT: Flush old textures to prevent memory leak
        CVMetalTextureCacheFlush(textureCache, 0)

        var metalTexture: CVMetalTexture?

        let result = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &metalTexture
        )

        guard result == kCVReturnSuccess,
              let texture = metalTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(texture)
    }

    // MARK: - Texture Loading
    
    /// Load an image as a texture for the mask overlay
    func loadMaskTexture(from image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("Failed to get CGImage from NSImage")
            return
        }
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: cgImage.width,
            height: cgImage.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        textureDescriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            print("Failed to create texture from image")
            return
        }
        
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * cgImage.width
        let bitmapData = UnsafeMutableRawPointer.allocate(byteCount: cgImage.height * bytesPerRow, alignment: 1)
        defer { bitmapData.deallocate() }
        
        guard let context = CGContext(
            data: bitmapData,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("Failed to create bitmap context")
            return
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: cgImage.width, height: cgImage.height, depth: 1))
        texture.replace(region: region, mipmapLevel: 0, withBytes: bitmapData, bytesPerRow: bytesPerRow)
        
        maskTexture = texture
        print("Loaded mask texture: \(cgImage.width)x\(cgImage.height)")
    }
    
    /// Clear the mask texture
    func clearMaskTexture() {
        maskTexture = nil
    }

    // MARK: - Export

    private func exportOutputTexture(at time: CMTime) {
        guard let outputTexture = outputTexture,
              let pixelBufferPool = pixelBufferPool else {
            print("exportOutputTexture: missing output texture or pool")
            return
        }

        var pixelBuffer: CVPixelBuffer?
        let poolStatus = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pixelBuffer)

        guard poolStatus == kCVReturnSuccess, let outputBuffer = pixelBuffer else {
            print("exportOutputTexture: failed to create pixel buffer from pool: \(poolStatus)")
            return
        }

        // For managed textures on macOS, synchronize GPU -> CPU
        // For managed textures on macOS, synchronization is done in the render command buffer


        // Lock the pixel buffer for writing
        CVPixelBufferLockBaseAddress(outputBuffer, [])

        guard let baseAddress = CVPixelBufferGetBaseAddress(outputBuffer) else {
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
            return
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(outputBuffer)
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: outputTexture.width,
                                           height: outputTexture.height,
                                           depth: 1))

        // Copy texture data to pixel buffer
        outputTexture.getBytes(baseAddress,
                              bytesPerRow: bytesPerRow,
                              from: region,
                              mipmapLevel: 0)

        CVPixelBufferUnlockBaseAddress(outputBuffer, [])

        // Notify delegate
        delegate?.renderer(self, didOutput: outputBuffer, at: time)
    }
}

// MARK: - Errors

enum MetalRendererError: LocalizedError {
    case deviceCreationFailed
    case textureCacheCreationFailed
    case pipelineCreationFailed
    case bufferCreationFailed

    var errorDescription: String? {
        switch self {
        case .deviceCreationFailed:
            return "Failed to create Metal device"
        case .textureCacheCreationFailed:
            return "Failed to create texture cache"
        case .pipelineCreationFailed:
            return "Failed to create render pipeline"
        case .bufferCreationFailed:
            return "Failed to create vertex buffer"
        }
    }
}
