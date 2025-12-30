//
//  pyatv_iosApp.swift
//  pyatv-ios
//
//  Created by Buseong Kim on 11/25/25.
//

import SwiftUI
import PylibKit_iOS

@main
struct pyatv_iosApp: App {

    private static var globalExecutor = PythonExecutor()

    init() {
    }

    var body: some Scene {
        WindowGroup {
            ContentView(executor: Self.globalExecutor)
        }
    }
}
