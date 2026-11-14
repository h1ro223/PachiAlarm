import Foundation
import AudioToolbox
import UserNotifications

/// ロック中の停止でも鳴らせるか試す「短いファンファーレ」(30秒以内)。
/// アプリ自身のオーディオ再生(AVAudioPlayer)がロック中に止められるので、別の経路を実機で比べる。
///  - システムサウンド: AudioServices で鳴らす(マナースイッチに従うと言われている)
///  - 通知音: ローカル通知の音をOSに鳴らしてもらう(アプリの再生許可が要らない)
enum FanfarePlayer {
    private static var systemSoundID: SystemSoundID = 0

    /// 設定に従って鳴らす。停止Intentの先頭で呼ぶ(BGMの再試行より先に)。
    static func playIfNeeded(reason: String) async {
        let s = SettingsStore.load()
        guard s.fanfareMode != .off else {
            DebugLog.shared.log("FANFARE", "方式=なし")
            return
        }
        guard let url = SoundLibrary.resolveFanfare(s.fanfareSound) else {
            DebugLog.shared.log("FANFARE", "ファンファーレ音が見つかりません: \(s.fanfareSound)")
            return
        }
        let seconds = SoundLibrary.duration(of: url)
        let dur = seconds.map { String(format: "%.1f秒", $0) } ?? "長さ不明"
        DebugLog.shared.log("FANFARE", "方式=\(s.fanfareMode.label) 音=\(url.lastPathComponent)(\(dur)) 理由=\(reason)")
        if let seconds, seconds > 30 {
            DebugLog.shared.log("FANFARE", "⚠️30秒を超えています。通知音は鳴らない可能性があります")
        }
        if s.fanfareMode == .systemSound || s.fanfareMode == .both {
            playSystemSound(url: url)
        }
        if s.fanfareMode == .notification || s.fanfareMode == .both {
            await postNotification(soundFileName: url.lastPathComponent, delay: 0)
        }
    }

    // MARK: - システムサウンド

    static func playSystemSound(url: URL) {
        if systemSoundID != 0 {
            AudioServicesDisposeSystemSoundID(systemSoundID)
            systemSoundID = 0
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
        guard status == kAudioServicesNoError else {
            DebugLog.shared.log("FANFARE", "システムサウンド作成失敗 status=\(status)")
            return
        }
        systemSoundID = id
        DebugLog.shared.log("FANFARE", "システムサウンド再生を依頼 id=\(id)")
        AudioServicesPlaySystemSoundWithCompletion(id) {
            DebugLog.shared.log("FANFARE", "システムサウンド再生が完了(終了通知)")
        }
    }

    // MARK: - 通知音

    static func authorizationText() async -> String {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let auth: String
        switch settings.authorizationStatus {
        case .authorized: auth = "許可済み"
        case .provisional: auth = "仮許可"
        case .ephemeral: auth = "一時許可"
        case .denied: auth = "拒否(設定アプリで許可が必要)"
        case .notDetermined: auth = "未確認"
        @unknown default: auth = "不明"
        }
        let sound: String
        switch settings.soundSetting {
        case .enabled: sound = "サウンドON"
        case .disabled: sound = "サウンドOFF"
        case .notSupported: sound = "サウンド非対応"
        @unknown default: sound = "不明"
        }
        return "\(auth) / \(sound)"
    }

    static func requestNotificationAuthorization() async {
        do {
            let ok = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            DebugLog.shared.log("FANFARE", "通知の許可リクエスト結果: \(ok)")
        } catch {
            DebugLog.shared.log("FANFARE", "通知の許可リクエスト失敗: \(error.localizedDescription)")
        }
    }

    /// 通知を出す。delay が 0 なら即時。
    static func postNotification(soundFileName: String, delay: TimeInterval) async {
        let center = UNUserNotificationCenter.current()
        let status = await authorizationText()
        let content = UNMutableNotificationContent()
        content.title = "大当たり!"
        content.body = "PachiAlarm"
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: soundFileName))
        let trigger: UNNotificationTrigger? = delay > 0
            ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
        let req = UNNotificationRequest(identifier: "pachi.fanfare.\(UUID().uuidString.prefix(6))",
                                        content: content, trigger: trigger)
        do {
            try await center.add(req)
            DebugLog.shared.log("FANFARE", "通知を登録しました 音=\(soundFileName) 通知設定=\(status)")
        } catch {
            DebugLog.shared.log("FANFARE", "通知の登録失敗: \(error.localizedDescription) 通知設定=\(status)")
        }
    }
}
