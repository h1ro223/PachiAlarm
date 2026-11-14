import Foundation
import SwiftUI
import AlarmKit
import ActivityKit
import AppIntents

/// AlarmKitに渡す追加情報(Phase 0では空)
struct PachiMetadata: AlarmMetadata {}

/// 副ボタンの種類。AlarmKitの副ボタンは1つだけなので、どれか1つを選ぶ。
enum SecondaryChoice: String, CaseIterable, Identifiable {
    case none, snooze, openApp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "なし(停止のみ)"
        case .snooze: return "スヌーズ"
        case .openApp: return "開く(アプリ起動)"
        }
    }
}

/// 停止ボタンの動作。ロック中の停止ではBGMを鳴らせなかったので、アプリを前面に開く版も試す。
enum StopMode: String, CaseIterable, Identifiable {
    case normal, openApp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .normal: return "通常(裏で処理)"
        case .openApp: return "アプリを開く(解除が必要)"
        }
    }
}

/// アラーム音の選択
enum SoundChoice: Hashable {
    case systemDefault
    case named(String)

    var label: String {
        switch self {
        case .systemDefault: return "システム標準"
        case .named(let n): return n
        }
    }
}

struct TestAlarmRequest {
    var title: String
    var fireDate: Date
    var repeatsDaily: Bool
    var sound: SoundChoice
    var secondary: SecondaryChoice
    var snoozeSeconds: Int
    /// 停止ボタンの動作(通常 / アプリを開く)
    var stopMode: StopMode = .normal
    /// true ならAlarmKitのカウントダウン(タイマー)方式。fireDateとの差の秒数で鳴る。短い秒数のテスト用。
    var useCountdown: Bool = false
}

struct AlarmRow: Identifiable {
    let id: UUID
    let state: String
    let meta: AlarmMeta?
}

/// AlarmKitの登録・取消・状態監視。状態の変化はすべてログに残す。
@MainActor
final class AlarmService: ObservableObject {
    @Published private(set) var authText = "-"
    @Published private(set) var rows: [AlarmRow] = []

    private var lastStates: [UUID: String] = [:]
    private var observeTask: Task<Void, Never>?

    init() {
        refreshAuth()
        startObserving()
        reload(source: "起動")
    }

    // MARK: - 許可

    var isAuthorized: Bool { AlarmManager.shared.authorizationState == .authorized }

    func refreshAuth() {
        switch AlarmManager.shared.authorizationState {
        case .authorized: authText = "許可済み"
        case .denied: authText = "拒否(設定アプリで許可が必要)"
        case .notDetermined: authText = "未確認"
        @unknown default: authText = "不明"
        }
    }

    func requestAuthorization() async {
        do {
            let state = try await AlarmManager.shared.requestAuthorization()
            DebugLog.shared.log("AUTH", "許可リクエスト結果: \(state)")
        } catch {
            DebugLog.shared.log("AUTH", "許可リクエスト失敗: \(error.localizedDescription)")
        }
        refreshAuth()
    }

    // MARK: - 一覧・状態監視

    func reload(source: String) {
        do {
            let list = try AlarmManager.shared.alarms
            apply(list, source: source)
        } catch {
            DebugLog.shared.log("ALARM", "一覧取得失敗: \(error.localizedDescription)")
        }
    }

    private func startObserving() {
        guard observeTask == nil else { return }
        observeTask = Task { [weak self] in
            for await list in AlarmManager.shared.alarmUpdates {
                self?.apply(list, source: "更新通知")
            }
        }
    }

    /// 状態の変化をログに残す。スヌーズと停止の区別はここで観察する。
    private func apply(_ list: [Alarm], source: String) {
        let meta = SettingsStore.load().alarmMeta
        var newStates: [UUID: String] = [:]
        for alarm in list {
            let state = String(describing: alarm.state)
            newStates[alarm.id] = state
            let old = lastStates[alarm.id]
            if old != state {
                var note = ""
                if old == "alerting" && state == "countdown" { note = " → スヌーズされた" }
                if state == "alerting" { note = " → 鳴動開始" }
                DebugLog.shared.log("ALARM", "[\(source)] \(alarm.id.uuidString.prefix(8)) \(old ?? "新規") → \(state)\(note)")
            }
        }
        for (id, old) in lastStates where newStates[id] == nil {
            let note = old == "alerting" ? "(鳴動中に消えた=停止された)" : "(取消または単発アラーム終了)"
            DebugLog.shared.log("ALARM", "[\(source)] \(id.uuidString.prefix(8)) 一覧から消えた \(note)")
        }
        lastStates = newStates
        rows = list
            .map { AlarmRow(id: $0.id, state: String(describing: $0.state), meta: meta[$0.id.uuidString]) }
            .sorted { ($0.meta?.createdAt ?? .distantPast) < ($1.meta?.createdAt ?? .distantPast) }
    }

    // MARK: - 登録

    @discardableResult
    func schedule(_ req: TestAlarmRequest) async -> Bool {
        if AlarmManager.shared.authorizationState == .notDetermined {
            await requestAuthorization()
        }
        guard isAuthorized else {
            DebugLog.shared.log("ALARM", "許可が無いため登録できません")
            return false
        }

        let id = UUID()
        let stopButton = AlarmButton(text: "停止", textColor: .white, systemImageName: "hand.tap.fill")

        let alert: AlarmPresentation.Alert
        var countdownDuration: Alarm.CountdownDuration? = nil
        let presentation: AlarmPresentation
        var secondaryIntent: (any LiveActivityIntent)? = nil
        // カウントダウン(タイマー)方式のときの待ち秒数。最低1秒。
        let timerSeconds = max(1, req.fireDate.timeIntervalSinceNow)
        // カウントダウン方式では、カウントダウン中の表示も必要になる
        let timerUI = AlarmPresentation.Countdown(title: "カウントダウン中", pauseButton: nil)

        switch req.secondary {
        case .none:
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: req.title),
                                            stopButton: stopButton,
                                            secondaryButton: nil,
                                            secondaryButtonBehavior: nil)
            presentation = req.useCountdown
                ? AlarmPresentation(alert: alert, countdown: timerUI)
                : AlarmPresentation(alert: alert)
        case .snooze:
            let snooze = AlarmButton(text: "スヌーズ", textColor: .white, systemImageName: "zzz")
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: req.title),
                                            stopButton: stopButton,
                                            secondaryButton: snooze,
                                            secondaryButtonBehavior: .countdown)
            countdownDuration = Alarm.CountdownDuration(preAlert: nil,
                                                        postAlert: TimeInterval(req.snoozeSeconds))
            let countdown = AlarmPresentation.Countdown(title: "スヌーズ中", pauseButton: nil)
            presentation = AlarmPresentation(alert: alert, countdown: countdown)
        case .openApp:
            let open = AlarmButton(text: "開く", textColor: .white, systemImageName: "arrow.up.forward.app")
            alert = AlarmPresentation.Alert(title: LocalizedStringResource(stringLiteral: req.title),
                                            stopButton: stopButton,
                                            secondaryButton: open,
                                            secondaryButtonBehavior: .custom)
            presentation = req.useCountdown
                ? AlarmPresentation(alert: alert, countdown: timerUI)
                : AlarmPresentation(alert: alert)
            secondaryIntent = PachiOpenAppIntent(alarmID: id.uuidString)
        }

        let attributes = AlarmAttributes<PachiMetadata>(presentation: presentation,
                                                        metadata: PachiMetadata(),
                                                        tintColor: Color(red: 1.0, green: 0.78, blue: 0.2))

        // カウントダウン方式: 待ち秒数(preAlert)で鳴らす。日時スケジュールは付けない。
        if req.useCountdown {
            countdownDuration = Alarm.CountdownDuration(
                preAlert: timerSeconds,
                postAlert: req.secondary == .snooze ? TimeInterval(req.snoozeSeconds) : nil)
        }

        let schedule: Alarm.Schedule?
        let comps = Calendar.current.dateComponents([.hour, .minute], from: req.fireDate)
        let fireText: String
        if req.useCountdown {
            schedule = nil
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            fireText = "タイマー \(Int(timerSeconds.rounded()))秒(\(f.string(from: req.fireDate))ごろ)"
        } else if req.repeatsDaily {
            let time = Alarm.Schedule.Relative.Time(hour: comps.hour ?? 7, minute: comps.minute ?? 0)
            let everyday: [Locale.Weekday] = [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday, .saturday]
            schedule = .relative(Alarm.Schedule.Relative(time: time, repeats: .weekly(everyday)))
            fireText = String(format: "毎日 %02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
        } else {
            schedule = .fixed(req.fireDate)
            let f = DateFormatter()
            f.dateFormat = "MM/dd HH:mm:ss"
            fireText = "単発 " + f.string(from: req.fireDate)
        }

        let sound: AlertConfiguration.AlertSound
        switch req.sound {
        case .systemDefault: sound = .default
        case .named(let name): sound = .named(name)
        }

        // 停止ボタンのIntent(通常=裏で処理 / アプリを開く)
        let stopIntent: any LiveActivityIntent
        if req.stopMode == .openApp {
            stopIntent = PachiStopOpenIntent(alarmID: id.uuidString)
        } else {
            stopIntent = PachiStopIntent(alarmID: id.uuidString)
        }

        let config = AlarmManager.AlarmConfiguration<PachiMetadata>(
            countdownDuration: countdownDuration,
            schedule: schedule,
            attributes: attributes,
            stopIntent: stopIntent,
            secondaryIntent: secondaryIntent,
            sound: sound)

        do {
            _ = try await AlarmManager.shared.schedule(id: id, configuration: config)
            let secondaryText = req.secondary == .snooze
                ? "スヌーズ\(req.snoozeSeconds)秒" : req.secondary.label
            SettingsStore.update {
                $0.alarmMeta[id.uuidString] = AlarmMeta(title: req.title, fireDescription: fireText,
                                                        soundLabel: req.sound.label,
                                                        secondaryLabel: secondaryText, createdAt: Date())
            }
            DebugLog.shared.log("ALARM", "登録OK \(id.uuidString.prefix(8)) \(fireText) 音=\(req.sound.label) 副ボタン=\(secondaryText) 停止=\(req.stopMode.label)")
            reload(source: "登録直後")
            return true
        } catch {
            DebugLog.shared.log("ALARM", "登録失敗: \(error)")
            return false
        }
    }

    // MARK: - 取消

    func cancel(_ id: UUID) async {
        do {
            try AlarmManager.shared.cancel(id: id)
            DebugLog.shared.log("ALARM", "取消 \(id.uuidString.prefix(8))")
        } catch {
            DebugLog.shared.log("ALARM", "取消失敗: \(error.localizedDescription)")
        }
        reload(source: "取消後")
    }

    func cancelAll() async {
        for row in rows { await cancel(row.id) }
        SettingsStore.update { $0.alarmMeta = [:] }
        reload(source: "全取消後")
    }
}
