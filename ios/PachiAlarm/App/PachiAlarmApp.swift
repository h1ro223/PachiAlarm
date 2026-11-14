import SwiftUI

@main
struct PachiAlarmApp: App {
    init() {
        SoundLibrary.ensureDirectories()
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        DebugLog.shared.log("APP", "起動 v\(v) iOS \(UIDevice.current.systemVersion) \(UIDevice.current.model)")
        let modes = (Bundle.main.infoDictionary?["UIBackgroundModes"] as? [String])?.joined(separator: ",") ?? "なし"
        DebugLog.shared.log("APP", "UIBackgroundModes=\(modes)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
