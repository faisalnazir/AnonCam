//
//  ViewController.swift
//  AnonCam
//
//  Main view controller with camera preview and controls
//

import AVFoundation
import Cocoa
import Combine
import CoreVideo
import MetalKit

final class ViewController: NSViewController {

    // MARK: - Outlets

    @IBOutlet var metalView: MTKView!
    @IBOutlet var statusLabel: NSTextField!
    @IBOutlet var startStopButton: NSButton!
    @IBOutlet var maskColorWell: NSColorWell!
    @IBOutlet var fpsLabel: NSTextField!
    @IBOutlet var resolutionLabel: NSTextField!

    // MARK: - Properties

    var viewModel: AppViewModel?

    private var cancellables = Set<AnyCancellable>()

    // Metal preview layer
    private var previewLayer: CAMetalLayer?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        setupMetalView()
        setupBindings()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
    }

    // MARK: - Setup

    private func setupMetalView() {
        guard let metalView = metalView else {
            // Create MTKView programmatically if not in storyboard
            let view = MTKView(frame: view.bounds)
            view.autoresizingMask = [.width, .height]
            self.view.addSubview(view)
            self.metalView = view
            return
        }

        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.framebufferOnly = false
        metalView.clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0)
    }

    private func setupBindings() {
        guard let viewModel = viewModel else { return }

        // Status binding
        viewModel.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.statusLabel?.stringValue = status
            }
            .store(in: &cancellables)

        // Running state binding
        viewModel.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                self?.startStopButton?.title = isRunning ? "Stop Camera" : "Start Camera"
                self?.startStopButton?.state = isRunning ? .on : .off
            }
            .store(in: &cancellables)

        // FPS binding
        viewModel.$fps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fps in
                self?.fpsLabel?.stringValue = String(format: "%.1f FPS", fps)
            }
            .store(in: &cancellables)

        // Resolution binding
        viewModel.$resolution
            .receive(on: DispatchQueue.main)
            .sink { [weak self] resolution in
                self?.resolutionLabel?.stringValue = "\(resolution.width) x \(resolution.height)"
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    @IBAction func startStopButtonClicked(_ sender: NSButton) {
        guard let viewModel = viewModel else { return }

        if viewModel.isRunning {
            viewModel.stop()
        } else {
            viewModel.start()
        }
    }

    @IBAction func maskColorChanged(_ sender: NSColorWell) {
        let color = sender.color
        viewModel?.maskColor = SIMD4<Float>(
            Float(color.redComponent),
            Float(color.greenComponent),
            Float(color.blueComponent),
            Float(color.alphaComponent)
        )
    }

    @IBAction func installExtensionButtonClicked(_ sender: NSButton) {
        // Trigger system extension installation
        NSApp.sendAction(#selector(AppDelegate.installExtension), to: nil, from: nil)
    }
}

// MARK: - Resolution helper

extension CGSize {
    var description: String {
        "\(Int(width)) x \(Int(height))"
    }
}
