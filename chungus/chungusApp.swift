//
//  chungusApp.swift
//  chungus
//
//  Created by Arjun Melwani on 2/14/26.
//

import SwiftUI

@main
struct chungusApp: App {
    init() {
        // Register default so the tunnel extension always sees blocking enabled
        // even before the user interacts with the toggle.
        UserDefaults(suiteName: BubbleConstants.appGroupID)?
            .register(defaults: [
                BubbleConstants.blockReelsEnabledKey: true
            ])
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
