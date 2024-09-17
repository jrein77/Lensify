//
//  AppDelegate.swift
//  Lensify
//
//  Created by Jake Reinhart on 7/7/24.
//

import UIKit
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .all
    }
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let newSessionId = UUID().uuidString
        UserDefaults.standard.set(newSessionId, forKey: "currentSessionId")
        print("New session started with ID: \(newSessionId)")
        
        // Prevent the app from going to black while open
        UIApplication.shared.isIdleTimerDisabled = true
        
        return true
    }
    
}

@main
struct SpectacleApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

