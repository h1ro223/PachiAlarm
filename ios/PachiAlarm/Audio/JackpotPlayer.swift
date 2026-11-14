import Foundation
import AVFoundation

/// アラーム停止後の大当たりBGMを鳴らす。
/// 検証ポイント:
///  - 停止ボタンのIntent(アプリはバックグラウンド起動)からオーディオを開始できるか
///  - ロック中のまま最後(1分52秒)まで鳴り切るか → 15秒ごとに再生位置をログに残す
@MainActor
final class JackpotPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = JackpotPlayer()

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var observersInstalled = false
    private var currentReason = ""

    var isPlaying: Bool { player?.isPlaying ?? false }

    /// 停止Intentから呼ぶ。設定を読み、待ち時間のあと再生する。
    func playAfterAlarmStop(alarmID: String) async -> Bool {
        let s = SettingsStore.load()
        guard s.bgmEnabled else {
            DebugLog.shared.log("BGM", "BGMは無効設定のため再生しません")
            return false
        }
        if s.bgmDelayMs > 0 {
            // アラーム音のオーディオが終わるのを少し待つ
            try? await Task.sleep(nanoseconds: UInt64(s.bgmDelayMs) * 1_000_000)
        }
        return play(settings: s, reason: "停止Intent id=\(alarmID.prefix(8))")
    }

    /// 再生(手動テストからも呼ぶ)。二重再生を防ぐため、再生中なら先に止める。
    @discardableResult
    func play(settings s: AppSettings, reason: String) -> Bool {
        guard let url = SoundLibrary.resolveBGM(s.selectedBGM) else {
            DebugLog.shared.log("BGM", "再生するファイルがありません")
            return false
        }
        if player != nil { stop(reason: "二重再生防止") }
        installObserversIfNeeded()
        guard activateSession(mode: s.audioMode) else { return false }

        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.volume = min(1, max(0, s.bgmVolume))
            p.numberOfLoops = 0
            p.prepareToPlay()
            let ok = p.play()
            player = p
            currentReason = reason
            let session = AVAudioSession.sharedInstance()
            DebugLog.shared.log("BGM", "play()=\(ok) 理由=\(reason) ファイル=\(url.lastPathComponent) "
                + "長さ=\(String(format: "%.1f", p.duration))秒 アプリ音量=\(p.volume) "
                + "端末メディア音量=\(String(format: "%.2f", session.outputVolume)) 出力=\(routeText())")
            if ok { startProgressTimer() } else { player = nil }
            return ok
        } catch {
            DebugLog.shared.log("BGM", "AVAudioPlayer作成失敗: \(describe(error))")
            return false
        }
    }

    func stop(reason: String) {
        progressTimer?.invalidate()
        progressTimer = nil
        if let p = player {
            DebugLog.shared.log("BGM", "停止(\(reason)) 位置=\(String(format: "%.1f", p.currentTime))秒")
            p.stop()
        }
        player = nil
        deactivateSession()
    }

    // MARK: - オーディオセッション

    private func activateSession(mode: AudioSessionMode) -> Bool {
        let session = AVAudioSession.sharedInstance()
        let attempts: [(String, AVAudioSession.CategoryOptions)]
        switch mode {
        case .exclusive: attempts = [("通常", [])]
        case .mix: attempts = [("ミックス", [.mixWithOthers])]
        case .auto: attempts = [("通常", []), ("ミックス", [.mixWithOthers])]
        }
        for (label, options) in attempts {
            do {
                try session.setCategory(.playback, mode: .default, options: options)
                try session.setActive(true)
                DebugLog.shared.log("AUDIO", "セッション開始OK(\(label))")
                return true
            } catch {
                DebugLog.shared.log("AUDIO", "セッション開始失敗(\(label)): \(describe(error))")
            }
        }
        return false
    }

    private func deactivateSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            DebugLog.shared.log("AUDIO", "セッション終了失敗: \(describe(error))")
        }
    }

    private func installObserversIfNeeded() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let nc = NotificationCenter.default
        nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 999
            let type = AVAudioSession.InterruptionType(rawValue: raw)
            DebugLog.shared.log("AUDIO", "割り込み: \(type == .began ? "開始" : type == .ended ? "終了" : "不明(\(raw))")")
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 999
            DebugLog.shared.log("AUDIO", "出力先変更 reason=\(raw)")
        }
    }

    // MARK: - 進捗ログ(ロック中に最後まで鳴ったかの確認用)

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
            Task { @MainActor in
                JackpotPlayer.shared.logProgress()
            }
        }
    }

    private func logProgress() {
        guard let p = player else { return }
        DebugLog.shared.log("BGM", "再生中 \(String(format: "%.0f", p.currentTime))/\(String(format: "%.0f", p.duration))秒 playing=\(p.isPlaying)")
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            DebugLog.shared.log("BGM", "再生完了 successfully=\(flag)(\(JackpotPlayer.shared.currentReason))")
            JackpotPlayer.shared.progressTimer?.invalidate()
            JackpotPlayer.shared.progressTimer = nil
            JackpotPlayer.shared.player = nil
            JackpotPlayer.shared.deactivateSession()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let msg = error.map { "\($0)" } ?? "不明"
        DebugLog.shared.log("BGM", "デコードエラー: \(msg)")
    }

    // MARK: - 補助

    private func routeText() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
    }

    private func describe(_ error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
    }
}
