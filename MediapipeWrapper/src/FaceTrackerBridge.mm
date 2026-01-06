//
//  FaceTrackerBridge.mm
//  AnonCam
//
//  Objective-C++ bridge implementation
//

#import "FaceTrackerBridge.h"
#include "FaceTracker.h"
#include <mutex>
#include <vector>

// ============================================================================
// Thread-local storage for result data
// ============================================================================

namespace {
    // Thread-local storage to keep C++ objects alive during C API usage
    thread_local std::vector<AnonCam::Landmark> t_landmarkBuffer;
    thread_local AnonCam::FaceResult t_lastResult;
}

// ============================================================================
// C API Implementation
// ============================================================================

extern "C" {

void* _Nullable ACMFaceTrackerCreate(const ACMFaceTrackerConfig* _Nullable config) {
    @try {
        AnonCam::FaceTracker::Config cppConfig;

        if (config) {
            cppConfig.maxNumFaces = config->maxNumFaces > 0 ? config->maxNumFaces : 1;
            cppConfig.minDetectionConfidence = config->minDetectionConfidence;
            cppConfig.minTrackingConfidence = config->minTrackingConfidence;
            cppConfig.enableSegmentation = config->enableSegmentation;
            cppConfig.useGPU = config->useGPU;
        } else {
            cppConfig.maxNumFaces = ACM_DEFAULT_MAX_NUM_FACES;
            cppConfig.minDetectionConfidence = ACM_DEFAULT_MIN_DETECTION_CONFIDENCE;
            cppConfig.minTrackingConfidence = ACM_DEFAULT_MIN_TRACKING_CONFIDENCE;
            cppConfig.enableSegmentation = ACM_DEFAULT_ENABLE_SEGMENTATION;
            cppConfig.useGPU = ACM_DEFAULT_USE_GPU;
        }

        auto tracker = new AnonCam::FaceTracker(cppConfig);
        if (!tracker->isInitialized()) {
            delete tracker;
            return nullptr;
        }

        return static_cast<void*>(tracker);
    } @catch (...) {
        return nullptr;
    }
}

void ACMFaceTrackerDestroy(void* _Nullable handle) {
    if (handle) {
        delete static_cast<AnonCam::FaceTracker*>(handle);
    }
}

ACMFaceResult ACMFaceTrackerProcess(void* _Nullable handle, CVPixelBufferRef _Nonnull pixelBuffer) {
    ACMFaceResult result = {};

    if (!handle || !pixelBuffer) {
        result.hasFace = false;
        result.landmarkCount = 0;
        result.landmarks = nullptr;
        return result;
    }

    @try {
        auto tracker = static_cast<AnonCam::FaceTracker*>(handle);
        t_lastResult = tracker->processFrame(pixelBuffer);

        // Convert C++ result to C struct
        result.hasFace = t_lastResult.hasFace;
        result.confidence = t_lastResult.confidence;
        result.landmarkCount = static_cast<int>(t_lastResult.landmarks.size());

        // Copy pose
        std::memcpy(result.pose.translation, t_lastResult.pose.translation, sizeof(result.pose.translation));
        std::memcpy(result.pose.rotation, t_lastResult.pose.rotation, sizeof(result.pose.rotation));
        std::memcpy(result.pose.modelMatrix, t_lastResult.pose.modelMatrix, sizeof(result.pose.modelMatrix));

        // Copy key points
        result.keyPoints.leftEye = {
            t_lastResult.keyPoints.leftEye.x,
            t_lastResult.keyPoints.leftEye.y,
            t_lastResult.keyPoints.leftEye.z
        };
        result.keyPoints.rightEye = {
            t_lastResult.keyPoints.rightEye.x,
            t_lastResult.keyPoints.rightEye.y,
            t_lastResult.keyPoints.rightEye.z
        };
        result.keyPoints.noseTip = {
            t_lastResult.keyPoints.noseTip.x,
            t_lastResult.keyPoints.noseTip.y,
            t_lastResult.keyPoints.noseTip.z
        };
        result.keyPoints.upperLip = {
            t_lastResult.keyPoints.upperLip.x,
            t_lastResult.keyPoints.upperLip.y,
            t_lastResult.keyPoints.upperLip.z
        };
        result.keyPoints.chin = {
            t_lastResult.keyPoints.chin.x,
            t_lastResult.keyPoints.chin.y,
            t_lastResult.keyPoints.chin.z
        };
        result.keyPoints.leftEar = {
            t_lastResult.keyPoints.leftEar.x,
            t_lastResult.keyPoints.leftEar.y,
            t_lastResult.keyPoints.leftEar.z
        };
        result.keyPoints.rightEar = {
            t_lastResult.keyPoints.rightEar.x,
            t_lastResult.keyPoints.rightEar.y,
            t_lastResult.keyPoints.rightEar.z
        };
        result.keyPoints.forehead = {
            t_lastResult.keyPoints.forehead.x,
            t_lastResult.keyPoints.forehead.y,
            t_lastResult.keyPoints.forehead.z
        };

        // Store landmarks in thread-local buffer
        t_landmarkBuffer = t_lastResult.landmarks;
        result.landmarks = t_landmarkBuffer.data();

        return result;

    } @catch (...) {
        result.hasFace = false;
        result.landmarkCount = 0;
        result.landmarks = nullptr;
        return result;
    }
}

void ACMFaceTrackerReset(void* _Nullable handle) {
    if (handle) {
        @try {
            auto tracker = static_cast<AnonCam::FaceTracker*>(handle);
            tracker->reset();
        } @catch (...) {
            // Ignore
        }
    }
}

ACMFaceResult ACMFaceTrackerGetLastResult(void* _Nullable handle) {
    ACMFaceResult result = {};

    if (!handle) {
        result.hasFace = false;
        result.landmarkCount = 0;
        result.landmarks = nullptr;
        return result;
    }

    @try {
        auto tracker = static_cast<AnonCam::FaceTracker*>(handle);
        t_lastResult = tracker->getLastResult();

        result.hasFace = t_lastResult.hasFace;
        result.confidence = t_lastResult.confidence;
        result.landmarkCount = static_cast<int>(t_lastResult.landmarks.size());

        std::memcpy(result.pose.translation, t_lastResult.pose.translation, sizeof(result.pose.translation));
        std::memcpy(result.pose.rotation, t_lastResult.pose.rotation, sizeof(result.pose.rotation));
        std::memcpy(result.pose.modelMatrix, t_lastResult.pose.modelMatrix, sizeof(result.pose.modelMatrix));

        t_landmarkBuffer = t_lastResult.landmarks;
        result.landmarks = t_landmarkBuffer.data();

        return result;
    } @catch (...) {
        result.hasFace = false;
        result.landmarkCount = 0;
        result.landmarks = nullptr;
        return result;
    }
}

bool ACMFaceTrackerIsInitialized(void* _Nullable handle) {
    if (!handle) {
        return false;
    }

    @try {
        auto tracker = static_cast<AnonCam::FaceTracker*>(handle);
        return tracker->isInitialized();
    } @catch (...) {
        return false;
    }
}

void ACMFaceResultRelease(ACMFaceResult result) {
    // No-op - landmarks are owned by thread-local storage
    // This function exists for API completeness and future extensions
}

} // extern "C"

// ============================================================================
// Objective-C Wrapper Implementation
// ============================================================================

@interface ACMFaceTracker () {
    std::unique_ptr<AnonCam::FaceTracker> _tracker;
}

@end

@implementation ACMFaceTracker

- (instancetype)init {
    return [self initWithConfig:(ACMFaceTrackerConfig){
        .maxNumFaces = ACM_DEFAULT_MAX_NUM_FACES,
        .minDetectionConfidence = ACM_DEFAULT_MIN_DETECTION_CONFIDENCE,
        .minTrackingConfidence = ACM_DEFAULT_MIN_TRACKING_CONFIDENCE,
        .enableSegmentation = ACM_DEFAULT_ENABLE_SEGMENTATION,
        .useGPU = ACM_DEFAULT_USE_GPU
    }];
}

- (instancetype)initWithConfig:(ACMFaceTrackerConfig)config {
    self = [super init];
    if (self) {
        _config = config;
        void* handle = ACMFaceTrackerCreate(&config);
        if (handle) {
            _tracker = std::unique_ptr<AnonCam::FaceTracker>(
                static_cast<AnonCam::FaceTracker*>(handle)
            );
        } else {
            return nil;
        }
    }
    return self;
}

- (void)dealloc {
    _tracker.reset();
}

- (ACMFaceResult)processFrame:(CVPixelBufferRef)pixelBuffer {
    if (!_tracker || !pixelBuffer) {
        ACMFaceResult empty = {};
        return empty;
    }
    return ACMFaceTrackerProcess(_tracker.get(), pixelBuffer);
}

- (void)reset {
    if (_tracker) {
        _tracker->reset();
    }
}

- (BOOL)isInitialized {
    return _tracker != nullptr && _tracker->isInitialized();
}

@end
