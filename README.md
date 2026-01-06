# AnonCam - Virtual Camera with Face Mask Overlay

A macOS virtual camera that applies a 3D anonymity mask to your face in real-time, outputting to any app that uses a camera (Zoom, FaceTime, browsers, etc.).

**Built with Apple's Vision framework for fast, efficient face tracking on the Neural Engine.**

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        AnonCamApp (Main App)                        │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐   │
│  │ CameraCapture│──▶│ FaceTracker  │──▶│   MetalRenderer      │   │
│  │  (AVCapture) │   │   (Vision)   │   │  (Mask + Compositing)│   │
│  └──────────────┘   └──────────────┘   └──────────────────────┘   │
│        ~1ms               ~2-5ms                 ~1ms               │
│                                                  │                   │
│                                                  ▼                   │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                  FrameRingBuffer (IPC)                      │   │
│  │              IOSurface-backed Shared Memory                 │   │
│  └─────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│               AnonCamCameraExtension (CMIO Extension)               │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────────┐   │
│  │   Provider   │──▶│    Device    │──▶│      Stream          │   │
│  └──────────────┘   └──────────────┘   └──────────────────────┘   │
│                              │                                     │
│                              ▼                                     │
│                     (To Zoom, Meet, etc.)                          │
└─────────────────────────────────────────────────────────────────────┘
```

## Features

- **Fast Face Tracking**: ~2-5ms per frame using Vision framework on Neural Engine
- **GPU Rendering**: Metal-accelerated mask compositing at 60 FPS
- **Zero-Copy IPC**: IOSurface-based shared memory for app→extension transfer
- **Multiple Mask Styles**: Helmet, organic, and low-poly mask options
- **Customizable**: Adjustable mask color and style

## Project Structure

```
AnonCam/
├── AnonCamApp/                    # Main app target
│   ├── Sources/
│   │   ├── Camera/                # Camera capture & face tracking
│   │   │   ├── CameraCapture.swift         # AVCaptureSession wrapper
│   │   │   ├── FaceTrackingResult.swift    # Data types
│   │   │   └── VisionFaceTracker.swift     # Vision framework
│   │   ├── Metal/                 # Rendering
│   │   │   ├── Shaders.metal               # Metal shaders
│   │   │   ├── MetalRenderer.swift         # Rendering pipeline
│   │   │   └── FrameExporter.swift         # MTLTexture → CVPixelBuffer
│   │   └── UI/                    # User interface
│   │       ├── AppDelegate.swift
│   │       ├── AppViewModel.swift
│   │       └── ViewController.swift
│   └── Supporting Files/
│       ├── Info.plist
│       └── AnonCamApp.entitlements
│
├── AnonCamCameraExtension/        # Camera extension target
│   ├── Sources/
│   │   ├── ExtensionProvider.swift
│   │   ├── ExtensionDevice.swift
│   │   └── ExtensionStream.swift
│   └── Supporting Files/
│       ├── Info.plist
│       └── AnonCamCameraExtension.entitlements
│
└── Shared/
    └── IPC/
        └── FrameRingBuffer.swift  # Shared memory IPC
```

## Performance on Apple Silicon

| Component | Time | Hardware |
|-----------|------|----------|
| Camera Capture | ~1ms | ISP |
| Face Tracking | 2-5ms | Neural Engine |
| Metal Render | ~1ms | GPU |
| IPC | ~0.5ms | IOSurface |
| **Total** | **~5-8ms** | **~120-200 FPS** |

## Building

### Prerequisites

- macOS 15.0+ (Sequoia)
- Xcode 16.0+
- Apple Silicon recommended (Intel also supported)

### Quick Start

```bash
# Clone the repository
cd AnonCam

# Open in Xcode
open AnonCam.xcodeproj

# Build and run (⌘R)
```

### Project Setup

1. **Create Xcode project**
   - New macOS App → Swift, SwiftUI
   - Add System Extension target (CMIO Camera Extension)
   - Embed extension in app

2. **Add source files** (see project structure above)

3. **Configure entitlements** (provided in Supporting Files/)

4. **Build and run**

## Installation & Usage

1. **Build** the app in Xcode
2. **Grant camera permission** when prompted
3. **Click "Install Virtual Camera"** in the menu bar
4. **Approve** the system extension in System Settings
5. **Start the camera** in AnonCam
6. **Select "AnonCam"** as your camera in other apps

### Testing

```bash
# Test in QuickTime
open -a "QuickTime Player"

# File → New Movie Recording
# Click camera dropdown → Select "AnonCam"
```

## Face Tracking with Vision Framework

The app uses Apple's built-in Vision framework:

```swift
import Vision

let tracker = VisionFaceTracker()
let result = tracker.processFrame(pixelBuffer)

// result.hasFace
// result.landmarks (all detected points)
// result.pose (head position/rotation)
// result.keyPoints (eyes, nose, etc.)
```

**Why Vision over MediaPipe?**

| | Vision | MediaPipe |
|---|--------|-----------|
| Performance | 2-5ms (Neural Engine) | 10-20ms (CPU) |
| Integration | Built-in framework | External dependency |
| Build | No extra steps | Bazel required |
| Stability | Apple-supported | Beta on macOS |
| GPU | Full acceleration | Limited Metal support |

## Mask Styles

```swift
// In AppViewModel
maskStyle = .helmet    // Smooth spherical mask
maskStyle = .organic   // Face-shaped contour
maskStyle = .lowPoly   // Angular geometric mask

// Custom color
maskColor = SIMD4<Float>(0.2, 0.3, 0.4, 1.0)
```

## CMIO Extension Details

The virtual camera is implemented as a CoreMediaIO System Extension:

- **Provider**: `ExtensionProvider` - Entry point, discovers devices
- **Device**: `ExtensionDevice` - Virtual camera device
- **Stream**: `ExtensionStream` - Outputs video frames

The extension receives frames via shared memory (`FrameRingBuffer`) using IOSurface for zero-copy transfer.

## Troubleshooting

### Extension Won't Install

```
System Settings → Privacy & Security
→ Look for "System software was blocked"
→ Click "Allow"
→ Try installation again
```

### Camera Not Showing

```bash
# Reset extension database
sudo systemextensionsctl reset

# Restart the app
```

### Performance Issues

- Ensure "High Performance" GPU mode (if on MacBook Pro)
- Check Activity Monitor for CPU usage
- Reduce camera resolution in CameraCapture config

## Resources

- [Apple: Vision Framework](https://developer.apple.com/documentation/vision)
- [Apple: Create camera extensions with Core Media IO](https://developer.apple.com/documentation/coremediaio/creating-a-camera-extension-with-core-media-i-o)
- [WWDC22: Create camera extensions](https://developer.apple.com/videos/play/wwdc2022/10022/)
- [ldenoue/cameraextension sample](https://github.com/ldenoue/cameraextension)

## License

MIT License
