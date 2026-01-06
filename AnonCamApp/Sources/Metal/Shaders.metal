//
//  Shaders.metal
//  AnonCam
//
//  Metal shaders for face mask rendering and compositing
//

#include <metal_stdlib>
using namespace metal;

// ============================================================================
// Common structures
// ============================================================================

/// Vertex input for camera quad
struct QuadVertex {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

/// Vertex input for 3D mask mesh
struct MaskVertex {
    float3 position [[attribute(0)]];
    float3 normal [[attribute(1)]];
    float2 texCoord [[attribute(2)]];
};

/// Uniforms for mask transform
struct MaskUniforms {
    float4x4 modelMatrix;
    float4x4 viewProjectionMatrix;
    float4 baseColor;
    float roughness;
    float metallic;
    float time;
    int hasFace;
};

/// Uniforms for camera background effects (Pixelation)
struct QuadUniforms {
    float4 faceRect; // x, y, w, h (normalized)
    int hasFace;
    float pixelSize; // e.g. 0.02
};

/// Vertex output passed to fragment shader (stage in)
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

// ============================================================================
// Camera background shader
// ============================================================================

/// Vertex shader for fullscreen quad displaying camera feed
vertex QuadFragmentIn quadVertexShader(QuadVertex in [[stage_in]]) {
    QuadFragmentIn out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    return out;
}

/// Fragment shader for camera background
/// Samples the camera texture and applies basic color correction
fragment float4 quadFragmentShader(
    QuadFragmentIn in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]],
    constant QuadUniforms &uniforms [[buffer(0)]]
) {
    float2 uv = in.texCoord;
    
    // Pixelation Effect
    if (uniforms.hasFace == 1) {
        float4 r = uniforms.faceRect;
        // Check if UV is inside face rect
        if (uv.x >= r.x && uv.x <= r.x + r.z &&
            uv.y >= r.y && uv.y <= r.y + r.w) {
            
            float pSize = uniforms.pixelSize;
            if (pSize <= 0.001) pSize = 0.02;
            
            // Snap UV to grid
            uv = floor(uv / pSize) * pSize + pSize * 0.5;
        }
    }

    float4 color = cameraTexture.sample(textureSampler, uv);

    // Basic color correction - adjust for typical webcam appearance
    color.rgb = pow(color.rgb, float3(0.95)); // Slight gamma adjust
    color.rgb = saturate(color.rgb);

    return color;
}

// ============================================================================
// Face mask shader - stylized anonymity mask
// ============================================================================

/// Vertex shader for 3D face mask
vertex MaskFragmentIn maskVertexShader(
    MaskVertex in [[stage_in]],
    constant MaskUniforms &uniforms [[buffer(0)]]
) {
    MaskFragmentIn out;

    // Transform to world space
    float4 worldPos = uniforms.modelMatrix * float4(in.position, 1.0);
    out.worldPos = worldPos.xyz;

    // Transform to clip space
    float4 viewPos = uniforms.viewProjectionMatrix * worldPos;
    out.position = viewPos;

    // Transform normal (using normal matrix for non-uniform scaling)
    float3x3 normalMatrix = float3x3(uniforms.modelMatrix[0].xyz,
                                     uniforms.modelMatrix[1].xyz,
                                     uniforms.modelMatrix[2].xyz);
    out.normal = normalize(normalMatrix * in.normal);

    out.texCoord = in.texCoord;

    // Calculate view direction (camera is at -Z looking +Z)
    out.viewDir = normalize(-worldPos.xyz);

    return out;
}

/// Fragment shader for stylized mask
/// Renders a smooth, matte surface that fully occludes the face
fragment float4 maskFragmentShader(
    MaskFragmentIn in [[stage_in]],
    constant MaskUniforms &uniforms [[buffer(0)]]
) {
    if (uniforms.hasFace == 0) {
        return float4(0.0);  // No face, return transparent
    }

    // Normalize inputs
    float3 N = normalize(in.normal);
    float3 V = normalize(in.viewDir);

    // Simple two-tone lighting
    float3 lightDir1 = normalize(float3(1.0, 1.0, 1.0));
    float3 lightDir2 = normalize(float3(-0.5, 0.5, -1.0));

    float NdotL1 = max(0.0, dot(N, lightDir1));
    float NdotL2 = max(0.0, dot(N, lightDir2));

    // Subtle rim lighting for edge definition
    float rim = 1.0 - max(0.0, dot(N, V));
    rim = pow(rim, 3.0);

    // Base color with lighting
    float3 baseColor = uniforms.baseColor.rgb;
    float3 litColor = baseColor * (0.4 + 0.4 * NdotL1 + 0.2 * NdotL2);

    // Add rim light
    litColor += rim * 0.15 * float3(1.0, 1.0, 1.0);

    // Very subtle animated pattern
    float pattern = sin(in.worldPos.x * 20.0 + uniforms.time) *
                    cos(in.worldPos.y * 20.0 + uniforms.time * 0.7);
    litColor += pattern * 0.02;

    float alpha = uniforms.baseColor.a;

    return float4(litColor, alpha);
}

// ============================================================================
// Alternative: Wireframe mask style
// ============================================================================

fragment float4 maskWireframeFragmentShader(
    MaskFragmentIn in [[stage_in]],
    constant MaskUniforms &uniforms [[buffer(0)]]
) {
    if (uniforms.hasFace == 0) {
        return float4(0.0);  // No face, return transparent
    }

    // Barycentric-based wireframe (requires barycentric coords as attribute)
    // For now, using a simpler edge detection approach

    float2 uv = in.texCoord;

    // Create grid pattern
    float scale = 30.0;
    float2 grid = abs(fract(uv * scale - 0.5) - 0.5) / fwidth(uv * scale);
    float line = min(grid.x, grid.y);
    float3 wireColor = mix(uniforms.baseColor.rgb, float3(1.0), 1.0 - smoothstep(0.0, 0.1, line));

    float alpha = uniforms.baseColor.a * (1.0 - smoothstep(0.0, 0.05, line));

    return float4(wireColor, alpha);
}

// ============================================================================
// Depth composite shader
// ============================================================================

/// Fragment shader that composites camera and mask based on depth
/// Mask writes to depth buffer, camera uses depth test
fragment float4 compositeFragmentShader(
    QuadFragmentIn in [[stage_in]],
    texture2d<float> cameraTexture [[texture(0)]],
    texture2d<float> maskTexture [[texture(1)]],
    sampler textureSampler [[sampler(0)]]
) {
    float2 uv = in.texCoord;

    // Sample camera and mask
    float4 cameraColor = cameraTexture.sample(textureSampler, uv);
    float4 maskColor = maskTexture.sample(textureSampler, uv);

    // Simple alpha blend (mask should have premultiplied alpha)
    float3 finalColor = mix(cameraColor.rgb, maskColor.rgb, maskColor.a);

    return float4(finalColor, 1.0);
}

// ============================================================================
// Post-processing shader
// ============================================================================

struct PostProcessUniforms {
    float exposure;
    float contrast;
    float saturation;
    float vignetteIntensity;
};

fragment float4 postProcessFragmentShader(
    QuadFragmentIn in [[stage_in]],
    texture2d<float> inputTexture [[texture(0)]],
    constant PostProcessUniforms &uniforms [[buffer(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    float2 uv = in.texCoord;

    // Sample
    float4 color = inputTexture.sample(textureSampler, uv);

    // Exposure
    color.rgb *= uniforms.exposure;

    // Contrast (around 0.5)
    color.rgb = (color.rgb - 0.5) * uniforms.contrast + 0.5;

    // Saturation
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, uniforms.saturation);

    // Vignette
    float2 center = uv - 0.5;
    float vignette = 1.0 - dot(center, center) * uniforms.vignetteIntensity;
    color.rgb *= vignette;

    return color;
}

// ============================================================================
// Vertex buffers for common geometry
// ============================================================================

constant float2 quadVertices[] = {
    float2(-1.0, -1.0),
    float2(1.0, -1.0),
    float2(-1.0, 1.0),
    float2(1.0, 1.0)
};

constant float2 quadTexCoords[] = {
    float2(0.0, 1.0), // Flip Y for Metal
    float2(1.0, 1.0),
    float2(0.0, 0.0),
    float2(1.0, 0.0)
};

/// Simple vertex shader using constant buffers
vertex QuadFragmentIn simpleQuadVertex(
    uint vertexID [[vertex_id]]
) {
    QuadFragmentIn out;
    out.position = float4(quadVertices[vertexID], 0.0, 1.0);
    out.texCoord = quadTexCoords[vertexID];
    return out;
}
