//
//  MarathonApp.swift
//  Marathon
//
//  Created by Marcus Price on 11/11/25.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct MarathonApp: App {
    @StateObject private var store = WorkoutStore()
    @AppStorage("appColorScheme") private var appColorScheme: String = "dark"

    private var preferredScheme: ColorScheme {
        appColorScheme == "light" ? .light : .dark
    }

    #if canImport(UIKit)
    // Forward APNs -> CloudKit notifications into the app so stores can react instantly.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil ||
                ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                // Synthetic unit tests must not launch live screen tasks.
                Color.clear
            } else {
                AppTabView()
                    .environmentObject(store)
                    .preferredColorScheme(preferredScheme)
                    .onAppear {
                        #if canImport(UIKit)
                        appDelegate.workoutStore = store
                        #endif
                    }
            }
        }
    }
}

#if canImport(UIKit)
final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var workoutStore: WorkoutStore?

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushSubscriptionManager.shared.didRegisterForRemoteNotifications(withDeviceToken: deviceToken)
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushSubscriptionManager.shared.didFailToRegisterForRemoteNotifications(error: error)
    }

    // CloudKit silent pushes arrive here; forward to the subscription manager to post our app‑internal notification.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task { @MainActor in
            let handled = PushSubscriptionManager.shared.handleRemoteNotification(userInfo: userInfo)
            guard handled, let store = workoutStore else {
                completionHandler(.noData)
                return
            }
            // Keep the background delivery alive until the shared snapshot has
            // refreshed. The store's observer joins this pass without forcing
            // a second fetch for the same notification.
            await store.refreshFromCloud(force: true)
            completionHandler(store.teamSyncError == nil ? .newData : .failed)
        }
    }
}
#endif
