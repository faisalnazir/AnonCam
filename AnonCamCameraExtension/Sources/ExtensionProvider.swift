//
//  ExtensionProvider.swift
//  AnonCamCameraExtension
//
//  CoreMediaIO Extension Provider - top-level object for the camera extension
//

import CoreMediaIO
import Foundation

/// The extension provider is the entry point for the virtual camera
/// It discovers and creates device sources
@objc(ExtensionProvider)
class ExtensionProvider: NSObject {

    // MARK: - Properties

    private let deviceSource: ExtensionDeviceSource

    var availableDevices: [ExtensionDeviceSource] {
        [deviceSource]
    }

    // MARK: - Initialization

    override init() {
        self.deviceSource = ExtensionDeviceSource()
        super.init()
    }
}

// MARK: - CMIOExtensionProvider

extension ExtensionProvider: CMIOExtensionProvider {

    var client: CMIOExtensionClient? {
        didSet {
            // Client connection changed
        }
    }

    var connected: Bool {
        // Always connected when extension is loaded
        true
    }

    var providerName: String {
        "AnonCam"
    }

    var providerVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var providerSource: CMIOExtensionProviderSource {
        // For Obj-C bridge pattern
        self
    }

    func setClient(_ client: CMIOExtensionClient?) {
        self.client = client
        deviceSource.client = client
    }

    func connect(to client: CMIOExtensionClient) async throws {
        self.client = client
        deviceSource.client = client
    }

    func disconnect(from client: CMIOExtensionClient) async {
        deviceSource.client = nil
        self.client = nil
    }

    func startStreaming() async throws {
        // Notify device to start streaming
        deviceSource.startStreaming()
    }

    func stopStreaming() async throws {
        deviceSource.stopStreaming()
    }

    // MARK: - Device Discovery

    func requestDeviceAuthorization(device: CMIOExtensionDevice) async throws -> Bool {
        // Grant access automatically - our app handles permissions
        true
    }

    func setDeviceProperties(device: CMIOExtensionDevice, properties: [String: Any]?) async throws {
        guard let deviceSource = device.deviceSource as? ExtensionDeviceSource else {
            return
        }

        // Update device properties
        if let properties = properties {
            deviceSource.updateProperties(properties)
        }
    }
}

// MARK: - CMIOExtensionProviderSource

extension ExtensionProvider: CMIOExtensionProviderSource {

    var providerDeviceSources: [CMIOExtensionDeviceSource] {
        [deviceSource]
    }

    var deviceSinks: [CMIOExtensionDeviceSink] {
        [] // No sink streams for simple source-only extension
    }
}
