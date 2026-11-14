import Foundation
import AppIntents
import AlarmKit
import UIKit

/// アラームの「停止」ボタンで実行されるIntent。
/// アプリが起動していなくても、OSがアプリをバックグラウンドで起動してperform()を呼ぶ(と公式に案内されている)。
/// 検証ポイント:
///  - ロック中の停止で呼ばれるか / ロック解除中・電源ボタン・スワイプで呼ばれるか
///  - ここから大当たりBGMを開始できるか
struct PachiStopIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止して大当たり"
    static var description = IntentDescription("PachiAlarmのアラームを停止し、大当たりBGMを再生します。")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() { self.alarmID = "" }
    init(alarmID: String) { self.alarmID = alarmID }

    func perform() async throws -> some IntentResult {
        let env = await IntentEnvironment.snapshot()
        DebugLog.shared.log("STOP", "★stopIntent 呼び出し id=\(alarmID.prefix(8)) \(env)")

        if let id = UUID(uuidString: alarmID) {
            do {
                // Apple公式サンプルと同じく、Intent内でも停止を指示する
                try await AlarmManager.shared.stop(id: id)
                DebugLog.shared.log("STOP", "AlarmManager.stop 成功")
            } catch {
                // すでにシステムが止めている場合もここに来る(報告あり)
                DebugLog.shared.log("STOP", "AlarmManager.stop 例外(既に停止済みの可能性): \(error.localizedDescription)")
            }
        }

        SettingsStore.update {
            $0.lastJackpotAlarmID = alarmID
            $0.lastJackpotAt = Date()
        }

        let started = await JackpotPlayer.shared.playAfterAlarmStop(alarmID: alarmID)
        DebugLog.shared.log("STOP", "大当たりBGM開始=\(started)")
        return .result()
    }
}

/// 副ボタンを「開く」にしたテスト用(ジャグラーモードの事前検証)。
/// 押すとアラームを止めてアプリを前面に出す。
struct PachiOpenAppIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "アプリを開く"
    static var description = IntentDescription("アラームを止めてPachiAlarmを開きます。")
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() { self.alarmID = "" }
    init(alarmID: String) { self.alarmID = alarmID }

    func perform() async throws -> some IntentResult {
        let env = await IntentEnvironment.snapshot()
        DebugLog.shared.log("OPEN", "★openIntent 呼び出し id=\(alarmID.prefix(8)) \(env)")
        if let id = UUID(uuidString: alarmID) {
            do {
                try await AlarmManager.shared.stop(id: id)
                DebugLog.shared.log("OPEN", "AlarmManager.stop 成功")
            } catch {
                DebugLog.shared.log("OPEN", "AlarmManager.stop 例外: \(error.localizedDescription)")
            }
        }
        SettingsStore.update { $0.openFromAlarmAt = Date() }
        return .result()
    }
}

/// Intent実行時の状況(アプリの状態・ロック状態)をログ用の文字列にする
enum IntentEnvironment {
    @MainActor
    static func snapshot() -> String {
        let app = UIApplication.shared
        let state: String
        switch app.applicationState {
        case .active: state = "前面"
        case .inactive: state = "非アクティブ"
        case .background: state = "バックグラウンド"
        @unknown default: state = "不明"
        }
        // パスコード設定時、ロック中は false になる(パスコード無しだと常に true)
        let locked = app.isProtectedDataAvailable ? "解除中の可能性" : "ロック中"
        return "アプリ状態=\(state) 端末=\(locked)"
    }
}
