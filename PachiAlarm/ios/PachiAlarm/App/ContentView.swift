import SwiftUI
import UniformTypeIdentifiers

/// BGM設定。値を変えるたびに、その項目だけ設定ファイルへ保存する
/// (停止Intentが書いた値を上書きしないため)。
@MainActor
final class BGMSettingsModel: ObservableObject {
    @Published var enabled: Bool { didSet { SettingsStore.update { [enabled] in $0.bgmEnabled = enabled } } }
    @Published var selected: String { didSet { SettingsStore.update { [selected] in $0.selectedBGM = selected } } }
    @Published var volume: Float { didSet { SettingsStore.update { [volume] in $0.bgmVolume = volume } } }
    @Published var delayMs: Int { didSet { SettingsStore.update { [delayMs] in $0.bgmDelayMs = delayMs } } }
    @Published var mode: AudioSessionMode { didSet { SettingsStore.update { [mode] in $0.audioMode = mode } } }

    init() {
        let s = SettingsStore.load()
        enabled = s.bgmEnabled
        selected = s.selectedBGM
        volume = s.bgmVolume
        delayMs = s.bgmDelayMs
        mode = s.audioMode
    }
}

private enum ImportTarget { case alarmSound, bgm }

private enum TimeChoice: String, CaseIterable, Identifiable {
    case m1, m2, m5, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .m1: return "1分後"
        case .m2: return "2分後"
        case .m5: return "5分後"
        case .custom: return "時刻指定"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .m1: return 60
        case .m2: return 120
        case .m5: return 300
        case .custom: return nil
        }
    }
}

struct ContentView: View {
    @StateObject private var alarms = AlarmService()
    @StateObject private var bgm = BGMSettingsModel()
    @Environment(\.scenePhase) private var scenePhase

    // テストアラーム作成
    @State private var title = "押せ！"
    @State private var timeChoice: TimeChoice = .m1
    @State private var customTime = Date().addingTimeInterval(180)
    @State private var repeatsDaily = false
    @State private var soundChoice: SoundChoice = .systemDefault
    @State private var secondary: SecondaryChoice = .snooze
    @State private var snoozeSeconds = 60

    // 音声一覧
    @State private var bundled: [SoundItem] = []
    @State private var imported: [SoundItem] = []
    @State private var bgmFiles: [SoundItem] = []

    @State private var importTarget: ImportTarget = .alarmSound
    @State private var showImporter = false
    @State private var logText = ""
    @State private var banner: String?
    @State private var lastJackpotText = "-"
    @State private var busy = false

    private let githubURL = URL(string: "https://github.com/h1ro223")!

    var body: some View {
        NavigationStack {
            Form {
                if let banner {
                    Section { Text(banner).font(.headline).foregroundStyle(.orange) }
                }
                statusSection
                createSection
                alarmListSection
                alarmSoundSection
                bgmSection
                logSection
                creditSection
            }
            .navigationTitle("PachiAlarm Phase 0")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tint(Color(red: 1.0, green: 0.78, blue: 0.2))
        .preferredColorScheme(.dark)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio],
                      allowsMultipleSelection: false) { result in
            handleImport(result)
        }
        .onAppear { refreshAll() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                DebugLog.shared.log("APP", "前面に表示")
                refreshAll()
                checkOpenedFromAlarm()
            }
        }
    }

    // MARK: - 状態

    private var statusSection: some View {
        Section("状態") {
            LabeledContent("AlarmKit許可", value: alarms.authText)
            if !alarms.isAuthorized {
                Button("アラームの使用を許可する") {
                    Task { await alarms.requestAuthorization() }
                }
            }
            LabeledContent("iOS", value: UIDevice.current.systemVersion)
            LabeledContent("最後の大当たり", value: lastJackpotText)
        }
    }

    // MARK: - テストアラーム作成

    private var createSection: some View {
        Section {
            TextField("タイトル", text: $title)
            Picker("時刻", selection: $timeChoice) {
                ForEach(TimeChoice.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if timeChoice == .custom {
                DatePicker("鳴らす時刻", selection: $customTime, displayedComponents: .hourAndMinute)
            }
            Toggle("毎日くり返す", isOn: $repeatsDaily)
            Picker("アラーム音", selection: $soundChoice) {
                Text("システム標準").tag(SoundChoice.systemDefault)
                ForEach(bundled) { item in
                    Text("[同梱] \(item.name) \(item.durationText)").tag(SoundChoice.named(item.name))
                }
                ForEach(imported) { item in
                    Text("[取込] \(item.name) \(item.durationText)").tag(SoundChoice.named(item.name))
                }
            }
            Picker("副ボタン", selection: $secondary) {
                ForEach(SecondaryChoice.allCases) { Text($0.label).tag($0) }
            }
            if secondary == .snooze {
                Stepper("スヌーズ \(snoozeSeconds)秒", value: $snoozeSeconds, in: 30...900, step: 30)
            }
            Button {
                Task { await createAlarm() }
            } label: {
                Label(busy ? "登録中…" : "テストアラームを登録", systemImage: "alarm.fill")
                    .font(.headline)
            }
            .disabled(busy)
        } header: {
            Text("テストアラーム作成")
        } footer: {
            Text("登録したら画面をロックして待ってください。停止ボタンを押すと大当たりBGMが鳴るかを検証します。")
        }
    }

    // MARK: - 登録済みアラーム

    private var alarmListSection: some View {
        Section("登録済みアラーム(\(alarms.rows.count))") {
            if alarms.rows.isEmpty {
                Text("なし").foregroundStyle(.secondary)
            }
            ForEach(alarms.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(row.meta?.fireDescription ?? "不明") 【\(row.state)】").font(.subheadline.bold())
                    Text("音: \(row.meta?.soundLabel ?? "-") / 副: \(row.meta?.secondaryLabel ?? "-")")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(row.id.uuidString.prefix(8)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("取消", role: .destructive) {
                        Task { await alarms.cancel(row.id) }
                    }
                }
            }
            if !alarms.rows.isEmpty {
                Button("すべて取消", role: .destructive) {
                    Task { await alarms.cancelAll() }
                }
            }
            Button("一覧を再読み込み") { alarms.reload(source: "手動") }
        }
    }

    // MARK: - アラーム音

    private var alarmSoundSection: some View {
        Section {
            Button {
                importTarget = .alarmSound
                showImporter = true
            } label: {
                Label("アラーム音を取り込む(Library/Sounds)", systemImage: "square.and.arrow.down")
            }
            ForEach(imported) { item in
                HStack {
                    Text(item.name).font(.caption)
                    Spacer()
                    Text(item.durationText).font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button("削除", role: .destructive) { deleteSound(item) }
                }
            }
        } header: {
            Text("アラーム音")
        } footer: {
            Text("取り込むと「元の形式」と「CAF変換版」の2つができます。どちらがロック画面で鳴るかを比べてください。30秒未満を推奨。")
        }
    }

    // MARK: - 大当たりBGM

    private var bgmSection: some View {
        Section {
            Toggle("停止後に大当たりBGMを鳴らす", isOn: $bgm.enabled)
            Picker("BGM", selection: $bgm.selected) {
                Text("[同梱] ダミーBGM 30秒").tag("")
                ForEach(bgmFiles) { item in
                    Text("\(item.name) \(item.durationText)").tag(item.name)
                }
            }
            VStack(alignment: .leading) {
                Text("BGM音量(アプリ内) \(Int(bgm.volume * 100))%")
                Slider(value: $bgm.volume, in: 0...1, step: 0.05)
            }
            Stepper("停止からの待ち \(bgm.delayMs)ms", value: $bgm.delayMs, in: 0...3000, step: 250)
            Picker("セッション方式", selection: $bgm.mode) {
                ForEach(AudioSessionMode.allCases) { Text($0.label).tag($0) }
            }
            Button {
                importTarget = .bgm
                showImporter = true
            } label: {
                Label("BGMを取り込む", systemImage: "music.note")
            }
            HStack {
                Button("テスト再生") {
                    JackpotPlayer.shared.play(settings: SettingsStore.load(), reason: "手動テスト")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("BGMを止める", role: .destructive) {
                    JackpotPlayer.shared.stop(reason: "手動")
                }
                .buttonStyle(.borderless)
            }
            ForEach(bgmFiles) { item in
                Text(item.name).font(.caption)
                    .swipeActions {
                        Button("削除", role: .destructive) { deleteSound(item) }
                    }
            }
        } header: {
            Text("大当たりBGM")
        } footer: {
            Text("端末のメディア音量はアプリから変更しません(Appleが許可していないため)。ログに現在のメディア音量を記録するので、アラーム音との差の調整に使ってください。")
        }
    }

    // MARK: - ログ

    private var logSection: some View {
        Section {
            ScrollView(.vertical) {
                Text(logText)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 320)
            HStack {
                Button("更新") { logText = DebugLog.shared.readTail() }
                    .buttonStyle(.borderless)
                Spacer()
                ShareLink(item: DebugLog.shared.fileURL) {
                    Label("共有", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("消去", role: .destructive) {
                    DebugLog.shared.clear()
                    logText = DebugLog.shared.readTail()
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("検証ログ")
        } footer: {
            Text("ファイルアプリ →「このiPhone内」→ PachiAlarm → phase0-log.txt でも見られます。")
        }
    }

    // MARK: - 制作表記

    private var creditSection: some View {
        Section {
            VStack(spacing: 4) {
                Text("made by hiro / ヒロ")
                Link("https://github.com/h1ro223", destination: githubURL)
            }
            .font(.footnote)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 処理

    private func refreshAll() {
        alarms.refreshAuth()
        alarms.reload(source: "画面更新")
        bundled = SoundLibrary.bundledSounds()
        imported = SoundLibrary.librarySounds()
        bgmFiles = SoundLibrary.bgmFiles()
        logText = DebugLog.shared.readTail()
        let s = SettingsStore.load()
        if let at = s.lastJackpotAt {
            let f = DateFormatter()
            f.dateFormat = "MM/dd HH:mm:ss"
            lastJackpotText = f.string(from: at)
        }
    }

    private func checkOpenedFromAlarm() {
        let s = SettingsStore.load()
        guard let at = s.openFromAlarmAt else { return }
        if Date().timeIntervalSince(at) < 600 {
            banner = "アラームの「開く」ボタンから起動しました"
            DebugLog.shared.log("OPEN", "「開く」経由でアプリが前面になったことを確認")
        }
        SettingsStore.update { $0.openFromAlarmAt = nil }
    }

    private func createAlarm() async {
        busy = true
        defer { busy = false }
        let fireDate: Date
        if let sec = timeChoice.seconds {
            fireDate = Date().addingTimeInterval(sec)
        } else {
            fireDate = nextOccurrence(of: customTime)
        }
        let req = TestAlarmRequest(title: title.isEmpty ? "押せ！" : title,
                                   fireDate: fireDate,
                                   repeatsDaily: repeatsDaily,
                                   sound: soundChoice,
                                   secondary: secondary,
                                   snoozeSeconds: snoozeSeconds)
        await alarms.schedule(req)
        logText = DebugLog.shared.readTail()
    }

    /// 指定時刻(時:分)の次の発生日時。今日すでに過ぎていれば明日。
    private func nextOccurrence(of time: Date) -> Date {
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: time)
        var target = cal.date(bySettingHour: hm.hour ?? 7, minute: hm.minute ?? 0, second: 0, of: Date()) ?? Date()
        if target <= Date() { target = cal.date(byAdding: .day, value: 1, to: target) ?? target }
        return target
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            DebugLog.shared.log("IMPORT", "選択失敗: \(error.localizedDescription)")
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                switch importTarget {
                case .alarmSound:
                    try SoundLibrary.importAlarmSound(from: url)
                case .bgm:
                    let name = try SoundLibrary.importBGM(from: url)
                    bgm.selected = name
                }
            } catch {
                DebugLog.shared.log("IMPORT", "取り込み失敗: \(error.localizedDescription)")
            }
        }
        refreshAll()
    }

    private func deleteSound(_ item: SoundItem) {
        do {
            try SoundLibrary.delete(item)
            if item.location == .bgm && bgm.selected == item.name { bgm.selected = "" }
        } catch {
            DebugLog.shared.log("SOUND", "削除失敗: \(error.localizedDescription)")
        }
        refreshAll()
    }
}
