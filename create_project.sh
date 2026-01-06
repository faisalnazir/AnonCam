#!/bin/bash

# Create AnonCam Xcode project

PROJECT_DIR="/Users/faisal/Dev/AnonCam/AnonCam"
cd "$PROJECT_DIR"

# Clean up old project if exists
rm -rf AnonCam.xcodeproj

# Create Xcode project using xcodebuild
cat > AnonCamApp.swift << 'SWIFT'
import Cocoa
import AVFoundation

@main
struct AnonCamApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
SWIFT

echo "Project files are at: $PROJECT_DIR"
echo ""
echo "To create the Xcode project:"
echo "1. Open Xcode"
echo "2. File → New → Project"
echo "3. Choose 'macOS App' (Swift)"
echo "4. Product Name: AnonCamApp"
echo "5. Save to: $PROJECT_DIR"
echo ""
echo "Then add the System Extension target for the camera extension."
