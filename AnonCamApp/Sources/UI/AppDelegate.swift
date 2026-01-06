//
//  AppDelegate.swift
//  AnonCam
//
//  Main application delegate
//

import AVFoundation
import Cocoa
import OSLog
import SwiftUI
import SystemExtensions
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.anoncam", category: "AppDelegate")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    var statusItem: NSStatusItem?
    var viewModel: AppViewModel?

    // Window controllers
    var mainWindowController: NSWindowController?

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.log("AnonCam starting up")

        // Create the main view model
        viewModel = AppViewModel()

        // Setup status bar item
        setupStatusBar()

        // Setup main window
        setupMainWindow()

        // Check for camera permissions
        requestCameraPermission()

        // Check system extension status
        checkExtensionStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.log("AnonCam shutting down")
        viewModel?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow(nil)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in background (menu bar app)
        return false
    }

    // MARK: - Setup

    private func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "AnonCam")
            button.action = #selector(togglePopover)
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show AnonCam", action: #selector(showMainWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Start Camera", action: #selector(startCamera), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop Camera", action: #selector(stopCamera), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Install Virtual Camera", action: #selector(installExtension), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Uninstall Virtual Camera", action: #selector(uninstallExtension), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit AnonCam", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    private func setupMainWindow() {
        // Create window programmatically since we don't have a storyboard
        let contentView = ContentView(viewModel: viewModel!)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "AnonCam"
        window.contentView = NSHostingView(rootView: contentView)
        window.minSize = NSSize(width: 400, height: 550)

        let windowController = NSWindowController(window: window)
        self.mainWindowController = windowController

        // Show the window
        windowController.showWindow(nil)
    }

    // MARK: - Camera Permission

    private func requestCameraPermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted {
                        logger.log("Camera permission granted")
                        self?.viewModel?.permissionGranted = true
                    } else {
                        logger.log("Camera permission denied")
                        self?.showPermissionAlert()
                    }
                }
            }
        case .authorized:
            logger.log("Camera permission already granted")
            viewModel?.permissionGranted = true
        case .denied, .restricted:
            logger.log("Camera permission denied or restricted")
            showPermissionAlert()
        @unknown default:
            break
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Camera Access Required"
        alert.informativeText = "AnonCam needs camera access to apply the anonymity mask. Please grant permission in System Settings > Privacy & Security > Camera."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - System Extension

    private func checkExtensionStatus() {
        Task {
            let status = await SystemExtensionManager.shared.currentStatus()

            await MainActor.run {
                updateExtensionUI(for: status)
            }
        }
    }

    private func updateExtensionUI(for status: SystemExtensionManager.SystemExtensionStatus) {
        // Update menu items or UI based on extension status
        logger.log("Extension status: \(String(describing: status))")
    }

    // MARK: - Actions

    @objc private func togglePopover() {
        showMainWindow(nil)
    }

    @objc private func showMainWindow(_ sender: Any?) {
        mainWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func startCamera() {
        logger.log("Starting camera")
        viewModel?.start()
    }

    @objc private func stopCamera() {
        logger.log("Stopping camera")
        viewModel?.stop()
    }

    @objc func installExtension() {
        logger.log("Installing system extension")
        Task {
            do {
                try await SystemExtensionManager.shared.install()
                logger.log("Extension installed successfully")
            } catch {
                logger.log("Extension installation failed: \(error)")
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "Installation Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .critical
                    alert.runModal()
                }
            }
        }
    }

    @objc func uninstallExtension() {
        logger.log("Uninstalling system extension")
        Task {
            do {
                try await SystemExtensionManager.shared.uninstall()
                logger.log("Extension uninstalled successfully")
            } catch {
                logger.log("Extension uninstallation failed: \(error)")
            }
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - System Extension Manager

/// Manages the camera system extension lifecycle
actor SystemExtensionManager {

    static let shared = SystemExtensionManager()

    enum SystemExtensionStatus {
        case notInstalled
        case installed
        case activated
        case needsUpdate
    }

    enum Error: LocalizedError {
        case notAuthorized
        case installationFailed(String)
        case activationFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Not authorized to install system extension"
            case .installationFailed(let message):
                return "Installation failed: \(message)"
            case .activationFailed(let message):
                return "Activation failed: \(message)"
            }
        }
    }

    private var extensionRequest: OSSystemExtensionRequest?
    private var extensionStatus: SystemExtensionStatus = .notInstalled
    private var currentDelegate: ExtensionDelegate?

    func currentStatus() -> SystemExtensionStatus {
        // Note: OSSystemExtensionManager doesn't provide a direct way to query extension status.
        // Extension status is tracked via delegate callbacks during install/uninstall.
        // For now, return the cached status.
        return extensionStatus
    }

    func install() async throws {
        // Use OSSystemExtensionRequest to install
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            let request = OSSystemExtensionRequest.activationRequest(
                forExtensionWithIdentifier: "com.anoncam.extension",
                queue: .main
            )

            let delegate = ExtensionDelegate(
                onSuccess: { continuation.resume() },
                onFailure: { error in continuation.resume(throwing: error) }
            )
            // Store delegate to keep it alive
            self.currentDelegate = delegate
            request.delegate = delegate

            self.extensionRequest = request
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func uninstall() async throws {
        // Uninstall the system extension
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            let request = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: "com.anoncam.extension",
                queue: .main
            )

            let delegate = ExtensionDelegate(
                onSuccess: { continuation.resume() },
                onFailure: { error in continuation.resume(throwing: error) }
            )
            // Store delegate to keep it alive
            self.currentDelegate = delegate
            request.delegate = delegate

            self.extensionRequest = request
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    func activate() async throws {
        // The extension is activated automatically after installation
        // This method is a placeholder for explicit activation if needed
    }
}

// MARK: - Extension Delegate

private class ExtensionDelegate: NSObject, OSSystemExtensionRequestDelegate {
    private let onSuccess: () -> Void
    private let onFailure: (any Swift.Error) -> Void

    init(onSuccess: @escaping () -> Void, onFailure: @escaping (any Swift.Error) -> Void) {
        self.onSuccess = onSuccess
        self.onFailure = onFailure
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Swift.Error) {
        onFailure(error)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        // Show UI to prompt user to approve in System Preferences
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        return .replace
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            onSuccess()
        case .willCompleteAfterReboot:
            // Inform user they need to restart
            onFailure(SystemExtensionManager.Error.installationFailed("System restart required"))
        @unknown default:
            break
        }
    }
}

// MARK: - ContentView

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var hasTexture: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            // Preview area
            ZStack {
                Rectangle()
                    .fill(Color.black)
                    .frame(height: 240)
                    .cornerRadius(8)

                if let image = viewModel.previewImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 240)
                        .cornerRadius(8)
                } else {
                    VStack {
                        Image(systemName: "video.slash")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text(viewModel.isRunning ? "Processing..." : "Camera Off")
                            .foregroundColor(.gray)
                    }
                }

                // Overlay status
                if viewModel.isRunning {
                    VStack {
                        HStack {
                            Spacer()
                            Text(String(format: "%.0f FPS", viewModel.fps))
                                .font(.caption)
                                .padding(4)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                                .foregroundColor(.white)
                                .padding(8)
                        }
                        Spacer()
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                // Camera selection
                HStack {
                    Text("Camera:")
                    Picker("", selection: Binding(
                        get: { viewModel.selectedCameraId },
                        set: { viewModel.selectCamera(deviceId: $0) }
                    )) {
                        ForEach(viewModel.availableCameras, id: \.uniqueID) { camera in
                            Text(camera.localizedName).tag(camera.uniqueID)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 150)
                }

                HStack {
                    Text("Status:")
                    Text(viewModel.status)
                        .foregroundColor(viewModel.status.contains("Face detected") ? .green : .orange)
                }

                HStack {
                    Text("FPS:")
                    Text(String(format: "%.1f", viewModel.fps))
                }

                HStack {
                    Text("Resolution:")
                    Text("\(Int(viewModel.resolution.width)) x \(Int(viewModel.resolution.height))")
                }
            }
            .frame(maxWidth: 220)

            Divider()

            HStack(spacing: 12) {
                Button(viewModel.isRunning ? "Stop" : "Start") {
                    if viewModel.isRunning {
                        viewModel.stop()
                    } else {
                        viewModel.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.hasPermission)

                Button("Style: \(viewModel.maskStyle.rawValue)") {
                    viewModel.cycleMaskStyle()
                }
                .buttonStyle(.bordered)
            }
            
            // Mask scale slider
            HStack {
                Text("Size:")
                Slider(value: $viewModel.maskScale, in: 0.5...2.0, step: 0.1)
                    .frame(width: 150)
                Text(String(format: "%.1fx", viewModel.maskScale))
                    .frame(width: 40)
            }
            
            // Texture controls
            HStack(spacing: 12) {
                Button("Load Texture") {
                    loadTextureFromFile()
                }
                .buttonStyle(.bordered)
                
                Button("Clear Texture") {
                    viewModel.clearMaskTexture()
                    hasTexture = false
                }
                .buttonStyle(.bordered)
                .disabled(!hasTexture)
            }
            
            if hasTexture {
                if viewModel.textureFaceDetected {
                    Text("Texture loaded (face detected)")
                        .font(.caption)
                        .foregroundColor(.green)
                } else {
                    Text("Texture loaded (no face)")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if !viewModel.hasPermission {
                Text("Camera access required")
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding(16)
        .frame(width: 400, height: 550)
    }
    
    private func loadTextureFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Select an image for the mask texture"
        panel.prompt = "Load Texture"
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                viewModel.loadMaskTexture(from: url)
                hasTexture = true
            }
        }
    }
}
