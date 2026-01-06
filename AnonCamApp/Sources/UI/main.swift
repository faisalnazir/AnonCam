//
//  main.swift
//  AnonCam
//

import Cocoa
import SwiftUI

// App entry point
let app = NSApplication.shared

// Create delegate on main actor
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
}

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
