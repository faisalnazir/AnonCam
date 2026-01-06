#ifndef AnonCam_FaceTracker_h
#define AnonCam_FaceTracker_h

#include <vector>
#include <memory>
#include <CoreVideo/CoreVideo.h>

namespace AnonCam {

// Single 3D landmark point
struct Landmark {
    float x;  // Normalized [0, 1]
    float y;  // Normalized [0, 1]
    float z;  // Relative depth, roughly [-1, 1] with 0 at the face plane
};

// Head pose representation (simplified 6DOF)
struct HeadPose {
    float translation[3];   // tx, ty, tz
    float rotation[3];      // pitch, yaw, roll in radians
    // 4x4 transformation matrix (row-major, for Metal)
    float modelMatrix[16];
};

// Result from face tracking for a single frame
struct FaceResult {
    bool hasFace = false;
    float confidence = 0.0f;
    std::vector<Landmark> landmarks;  // 478 points for Face Mesh
    HeadPose pose;

    // Quick access to key landmarks for mask alignment
    struct KeyPoints {
        Landmark leftEye;
        Landmark rightEye;
        Landmark noseTip;
        Landmark upperLip;
        Landmark chin;
        Landmark leftEar;
        Landmark rightEar;
        Landmark forehead;
    } keyPoints;
};

/**
 * FaceTracker - MediaPipe Face Mesh wrapper for macOS
 *
 * Thread-safe: processFrame() may be called from any thread,
 * but each call should be serialized per instance.
 */
class FaceTracker {
public:
    struct Config {
        int maxNumFaces = 1;
        float minDetectionConfidence = 0.5f;
        float minTrackingConfidence = 0.5f;
        bool enableSegmentation = false;
        // Use CPU backend (Metal GPU support for MediaPipe on macOS is limited)
        bool useGPU = false;
    };

    explicit FaceTracker(const Config& config = Config());
    ~FaceTracker();

    // Non-copyable, movable
    FaceTracker(const FaceTracker&) = delete;
    FaceTracker& operator=(const FaceTracker&) = delete;
    FaceTracker(FaceTracker&&) noexcept;
    FaceTracker& operator=(FaceTracker&&) noexcept;

    /**
     * Process a frame and extract face landmarks
     * @param pixelBuffer CVPixelBufferRef from AVCaptureSession
     * @return FaceResult with landmarks and pose (hasFace = false if no face detected)
     */
    FaceResult processFrame(CVPixelBufferRef pixelBuffer);

    /**
     * Reset internal tracking state (call when camera restarts)
     */
    void reset();

    /**
     * Get last result without processing new frame
     */
    FaceResult getLastResult() const;

    /**
     * Check if tracker is initialized successfully
     */
    bool isInitialized() const { return initialized_; }

private:
    class Impl;
    std::unique_ptr<Impl> impl_;
    bool initialized_ = false;

    // Extract key points from full landmark set
    void extractKeyPoints(const std::vector<Landmark>& landmarks, FaceResult::KeyPoints& kp);

    // Compute head pose from landmarks
    void computeHeadPose(const std::vector<Landmark>& landmarks, HeadPose& pose);

    // Normalize model matrix for Metal
    void normalizeModelMatrix(const HeadPose& pose, float* matrix);
};

} // namespace AnonCam

#endif /* AnonCam_FaceTracker_h */
