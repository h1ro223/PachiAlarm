import Foundation

/// オーディオセッションの開始方法(停止後のBGMがロック中に鳴るかの検証用)
enum AudioSessionMode: String, Codable, CaseIterable, Identifiable {
    case auto       // まず通常で試し、失敗したらミックスで再試行
    case exclusive  // .playback(他の音を止める)
    case mix        // .playback + .mixWithOthers

    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "自動(通常→失敗時ミックス)"
        case .exclusive: return "通常(他の音を止める)"
        case .mix: return "ミックス(他の音と同時)"
        }
    }
}

/// 登録したテストアラームの情報(AlarmKit側には持たせられないのでアプリで保存)
struct AlarmMeta: Codable, Equatable {
    var title: String
    var fireDescription: String
    var soundLabel: String
    var secondaryLabel: String
    var createdAt: Date
}

/// アプリ設定。キーが欠けていても・壊れていても起動できるように手書きでデコードする。
struct AppSettings: Codable, Equatable {
    var bgmEnabled: Bool = true
    /// BGMフォルダ内のファイル名。空文字なら同梱ダミーBGM
    var selectedBGM: String = ""
    var bgmVolume: Float = 0.5
    var bgmDelayMs: Int = 500
    var audioMode: AudioSessionMode = .auto
    var alarmMeta: [String: AlarmMeta] = [:]
    var lastJackpotAlarmID: String? = nil
    var lastJackpotAt: Date? = nil
    /// アラームの「開く」ボタンで起動した時刻(画面にバナーを出す)
    var openFromAlarmAt: Date? = nil

    init() {}

    enum CodingKeys: String, CodingKey {
        case bgmEnabled, selectedBGM, bgmVolume, bgmDelayMs, audioMode,
             alarmMeta, lastJackpotAlarmID, lastJackpotAt, openFromAlarmAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        bgmEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .bgmEnabled)) ?? d.bgmEnabled
        selectedBGM = (try? c.decodeIfPresent(String.self, forKey: .selectedBGM)) ?? d.selectedBGM
        bgmVolume = (try? c.decodeIfPresent(Float.self, forKey: .bgmVolume)) ?? d.bgmVolume
        bgmDelayMs = (try? c.decodeIfPresent(Int.self, forKey: .bgmDelayMs)) ?? d.bgmDelayMs
        audioMode = (try? c.decodeIfPresent(AudioSessionMode.self, forKey: .audioMode)) ?? d.audioMode
        alarmMeta = (try? c.decodeIfPresent([String: AlarmMeta].self, forKey: .alarmMeta)) ?? d.alarmMeta
        lastJackpotAlarmID = (try? c.decodeIfPresent(String.self, forKey: .lastJackpotAlarmID))
        lastJackpotAt = (try? c.decodeIfPresent(Date.self, forKey: .lastJackpotAt))
        openFromAlarmAt = (try? c.decodeIfPresent(Date.self, forKey: .openFromAlarmAt))
        // 値の範囲チェック
        bgmVolume = min(1, max(0, bgmVolume))
        bgmDelayMs = min(5000, max(0, bgmDelayMs))
    }
}

/// 設定ファイル(Application Support/settings.json)の読み書き。
/// アプリ画面と停止Intentの両方から使うので、ロックで直列化する。
enum SettingsStore {
    private static let lock = NSLock()

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PachiAlarm", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
        return dir
    }

    static var fileURL: URL { directory.appendingPathComponent("settings.json") }

    static func load() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked()
    }

    static func save(_ settings: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        saveUnlocked(settings)
    }

    /// 読み込み→変更→保存をまとめて行う(他の箇所の変更を上書きしないため)
    static func update(_ body: (inout AppSettings) -> Void) {
        lock.lock(); defer { lock.unlock() }
        var s = loadUnlocked()
        body(&s)
        saveUnlocked(s)
    }

    private static func loadUnlocked() -> AppSettings {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return AppSettings() }
        do {
            let data = try Data(contentsOf: url)
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            return try dec.decode(AppSettings.self, from: data)
        } catch {
            // 壊れていたら退避して初期値で起動する
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("settings.broken-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            DebugLog.shared.log("SETTINGS", "設定ファイルが壊れていたので初期化しました: \(error.localizedDescription)")
            return AppSettings()
        }
    }

    private static func saveUnlocked(_ settings: AppSettings) {
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(settings)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            DebugLog.shared.log("SETTINGS", "保存失敗: \(error.localizedDescription)")
        }
    }
}
