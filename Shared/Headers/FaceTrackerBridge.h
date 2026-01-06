//
//  FaceTrackerBridge.h
//  AnonCam
//
//  Objective-C++ bridge for Swift integration with MediaPipe C++ FaceTracker
//

#ifndef AnonCam_FaceTrackerBridge_h
#define AnonCam_FaceTrackerBridge_h

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - C Types

/// Single 3D landmark point (matches C++ Landmark)
typedef struct {
    float x;  // Normalized [0, 1]
    float y;  // Normalized [0, 1]
    float z;  // Relative depth
} ACMLandmark;

/// Head pose representation
typedef struct {
    float translation[3];  // tx, ty, tz
    float rotation[3];     // pitch, yaw, roll in radians
    float modelMatrix[16]; // 4x4 transformation matrix (row-major)
} ACMHeadPose;

/// Key facial landmarks for quick access
typedef struct {
    ACMLandmark leftEye;
    ACMLandmark rightEye;
    ACMLandmark noseTip;
    ACMLandmark upperLip;
    ACMLandmark chin;
    ACMLandmark leftEar;
    ACMLandmark rightEar;
    ACMLandmark forehead;
} ACMKeyPoints;

/// Complete face tracking result
typedef struct {
    bool hasFace;
    float confidence;
    int landmarkCount;
    ACMLandmark *landmarks;     // Array of landmarks, owned by tracker
    ACMHeadPose pose;
    ACMKeyPoints keyPoints;
} ACMFaceResult;

#pragma mark - Configuration

/// FaceTracker configuration
typedef struct {
    int maxNumFaces;
    float minDetectionConfidence;
    float minTrackingConfidence;
    bool enableSegmentation;
    bool useGPU;
} ACMFaceTrackerConfig;

/// Default configuration values
#define ACM_DEFAULT_MAX_NUM_FACES 1
#define ACM_DEFAULT_MIN_DETECTION_CONFIDENCE 0.5f
#define ACM_DEFAULT_MIN_TRACKING_CONFIDENCE 0.5f
#define ACM_DEFAULT_ENABLE_SEGMENTATION false
#define ACM_DEFAULT_USE_GPU false

#pragma mark - C API

/// Create a new FaceTracker instance
/// @param config Configuration for the tracker (use NULL for defaults)
/// @return Opaque handle to the tracker instance
void* _Nullable ACMFaceTrackerCreate(const ACMFaceTrackerConfig* _Nullable config);

/// Destroy a FaceTracker instance
/// @param handle Handle from ACMFaceTrackerCreate
void ACMFaceTrackerDestroy(void* _Nullable handle);

/// Process a camera frame and extract face landmarks
/// @param handle Handle from ACMFaceTrackerCreate
/// @param pixelBuffer CVPixelBufferRef from AVCaptureSession
/// @return Face tracking result (valid until next processFrame call on same thread)
ACMFaceResult ACMFaceTrackerProcess(void* _Nullable handle, CVPixelBufferRef _Nonnull pixelBuffer);

/// Reset internal tracking state
/// @param handle Handle from ACMFaceTrackerCreate
void ACMFaceTrackerReset(void* _Nullable handle);

/// Get last result without processing a new frame
/// @param handle Handle from ACMFaceTrackerCreate
/// @return Last known face tracking result
ACMFaceResult ACMFaceTrackerGetLastResult(void* _Nullable handle);

/// Check if tracker is initialized successfully
/// @param handle Handle from ACMFaceTrackerCreate
/// @return true if ready to use
bool ACMFaceTrackerIsInitialized(void* _Nullable handle);

/// Release resources in a face result (only needed if copying results)
/// @param result Face result to release
void ACMFaceResultRelease(ACMFaceResult result);

#pragma mark - Objective-C Wrapper (for easier Swift interop)

NS_ASSUME_NONNULL_BEGIN

/// Swift-friendly wrapper for FaceTracker
@interface ACMFaceTracker : NSObject

/// Configuration
@property (nonatomic, readonly) ACMFaceTrackerConfig config;

/// Initialize with default or custom configuration
- (instancetype)init;
- (instancetype)initWithConfig:(ACMFaceTrackerConfig)config NS_DESIGNATED_INITIALIZER;

/// Process a frame
- (ACMFaceResult)processFrame:(CVPixelBufferRef)pixelBuffer;

/// Reset tracking state
- (void)reset;

/// Check if initialized
@property (nonatomic, readonly) BOOL isInitialized;

@end

NS_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif

#endif /* AnonCam_FaceTrackerBridge_h */
