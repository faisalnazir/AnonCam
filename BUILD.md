# AnonCam Build Guide

This document details the complete build process for AnonCam on macOS.

## Prerequisites

- macOS 15.0+ (Sequoia or later)
- Xcode 16.0+ with command line tools
- Apple Silicon (M4 Pro recommended) or Intel Mac
- Python 3.10+ (for MediaPipe Bazel builds, if building from source)

## Step 1: Set Up MediaPipe

### Option A: Use Pre-built MediaPipe (Recommended)

Download pre-built MediaPipe libraries for macOS:

```bash
# Create a directory for third-party dependencies
mkdir -p ThirdParty
cd ThirdParty

# Download MediaPipe macOS release (when available)
# or build from source using Option B
```

### Option B: Build MediaPipe from Source

```bash
# Install Bazel
brew install bazel

# Clone MediaPipe
git clone https://github.com/google-ai-edge/mediapipe.git
cd mediapipe

# Build FaceMesh calculator as a static library
bazel build -c opt --config=macos \
    //mediapipe/tasks/c/vision/face_landmarker:libface_landmarker.dylib

# Copy the library to AnonCam/ThirdParty
mkdir -p ../AnonCam/ThirdParty/lib
cp bazel-bin/mediapipe/tasks/c/vision/face_landmarker/libface_landmarker.dylib \
   ../AnonCam/ThirdParty/lib/
```

### Option C: Stub Implementation (For Development)

The provided `FaceTracker.cpp` includes a stub implementation that generates
mock face landmarks. This allows developing and testing the rest of the pipeline
without MediaPipe.

## Step 2: Configure Xcode Project

### Create the Project

```bash
cd AnonCam
open .
```

Then in Xcode:

1. File → New → Project
2. Choose **macOS → App**
3. Product Name: `AnonCamApp`
4. Interface: SwiftUI
5. Language: Swift
6. Save in the `AnonCam` directory

### Add Camera Extension Target

1. File → New → Target
2. Choose **System Extension → CMIO Camera Extension**
3. Product Name: `AnonCamCameraExtension`
4. Language: Swift
5. Embed in Application: `AnonCamApp`

### Configure Build Settings

**AnonCamApp target:**

```
Targeted Device Family: Mac
Mac Catalyst: No
Deployment Target: 15.0
```

**AnonCamCameraExtension target:**

```
Targeted Device Family: Mac
Deployment Target: 15.0
Bundle Identifier: com.anoncam.extension
```

**Linking:**

```
Other Linker Flags:
- -ObjC
- -lc++
```

**Header Search Paths:**
```
$(SRCROOT)/MediapipeWrapper/include
$(SRCROOT)/Shared/Headers
```

## Step 3: Add Source Files

### Drag folders into Xcode:

- `AnonCamApp/Sources/` → AnonCamApp target
- `AnonCamCameraExtension/Sources/` → AnonCamCameraExtension target
- `MediapipeWrapper/src/` → Both targets (or create aggregate target)
- `Shared/` → Both targets

### File Type Mapping:

- `.swift` → Swift
- `.metal` → Metal
- `.mm` → Objective-C++ (rename .m to .mm automatically)
- `.cpp` → C++
- `.h` → C Header

## Step 4: MediaPipe Integration

### Add MediaPipe Library

1. Add `libface_landmarker.dylib` to the project
2. Add to "Frameworks and Libraries" in both targets
3. Set "Embed" to "Yes" for AnonCamApp (extension will load from app)

### Update FaceTracker.cpp

Replace the stub implementation in `processFrame()` with actual MediaPipe calls:

```cpp
#include "mediapipe/tasks/c/vision/face_landmarker.h"

// In FaceTracker::Impl:
FaceLandmarker* landmarker = nullptr;

void Init() {
    // Create face landmarker options
    FaceLandmarkerOptions options;
    options.base_options.model_asset_path = "face_landmarker_v2.task";
    options.base_options.delegate = CPU;  // or GPU if Metal backend available

    // Create landmarker
    landmarker = FaceLandmarkerCreate(&options);
}

FaceResult processFrame(CVPixelBufferRef pixelBuffer) {
    // Convert CVPixelBuffer to MediaPipe Image
    MpImage image = {
        .type = MpImage::IMAGE_BUFFER,
        .image_buffer = {
            .buffer = pixelBuffer,
            .width = CVPixelBufferGetWidth(pixelBuffer),
            .height = CVPixelBufferGetHeight(pixelBuffer)
        }
    };

    // Run detection
    FaceLandmarkerResult* result = FaceLandmarkerDetect(landmarker, &image);

    // Convert to our format...
    // ...
}
```

## Step 5: Build and Run

### Debug Build

```bash
xcodebuild -scheme AnonCam \
    -configuration Debug \
    -derivedDataPath build \
    build
```

### Release Build

```bash
xcodebuild -scheme AnonCam \
    -configuration Release \
    -derivedDataPath build \
    build
```

### Archive

```bash
xcodebuild archive \
    -scheme AnonCam \
    -archivePath build/AnonCam.xcarchive \
    -derivedDataPath build
```

## Step 6: Install and Test

### First Run

1. Build and run the app
2. Grant camera permission when prompted
3. Click "Install Virtual Camera" in the menu bar
4. Approve the system extension in System Settings
5. If prompted, restart the computer

### Verify Installation

```bash
# Check if extension is loaded
systemextensionsctl list

# Should show something like:
# com.anoncam.extension [enabled activated]
```

### Test in Other Apps

1. Open QuickTime Player
2. File → New Movie Recording
3. Click the dropdown next to the record button
4. Select "AnonCam" as the camera
5. Verify the masked video feed appears

## Troubleshooting

### Extension Won't Install

- Check System Settings → Privacy & Security
- Look for "System software from developer 'Apple' was blocked"
- Click "Allow"
- Try installation again

### Extension Not Appearing

```bash
# Reset the extension database
sudo systemextensionsctl reset

# Reinstall the app
```

### MediaPipe Build Errors

- Ensure Bazel version matches MediaPipe requirements
- Try `bazel clean --expunge` if cache issues
- Use CPU delegate if Metal fails

### Camera Permission Denied

```bash
# Reset camera permissions
tccutil reset Camera com.anoncam.app
```

### Metal Shader Compilation Errors

- Verify Metal shaders use valid syntax
- Check shader compilation logs in Console.app
- Ensure `MTLLibrary` is created successfully

## Performance Tuning

### Target 30 FPS @ 1080p

```swift
// In CameraCapture.swift
let config = CameraCaptureConfiguration(
    preset: .high,
    frameRate: 30
)
```

### Reduce CPU Usage

- Use GPU delegate for MediaPipe (when available)
- Reduce face mesh resolution
- Skip frames when processing backlog

### Optimize Memory

- Use pixel buffer pooling
- Limit ring buffer to 3 frames
- Release textures promptly

## Signing for Distribution

### Developer ID

```bash
# Code sign with Developer ID
codesign --force --deep --sign "Developer ID Application: Your Name" \
    AnonCam.app
```

### Notarization

```bash
# Notarize the app
xcrun notarytool submit AnonCam.dmg \
    --apple-id "your@email.com" \
    --password "app-specific-password" \
    --team-id "TEAMID" \
    --wait
```

### Stapling

```bash
# Staple the ticket to the app
xcrun stapler staple AnonCam.app
```
