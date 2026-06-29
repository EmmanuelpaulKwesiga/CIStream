//
//  CIStreamApp.swift
//  CIStream
//
//  Created by Emmanuel Kwesiga on 22/06/2026.
//

import SwiftUI
import SwiftData

@main
struct CIStreamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: SessionRecord.self)
    }
}
