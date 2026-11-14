import Foundation
import AVFoundation

/// 音声ファイル1つぶんの情報
struct SoundItem: Identifiable, Hashable {
    enum Location: String { case bundle, librarySounds, bgm }
    let name: String
    let location: Location
    let duration: Double?

    var id: String { location.rawValue + ":" + name }

    var durationText: String {
        guard let d = duration else { return "長さ不明" }
        return String(format: "%.1f秒", d)
    }
}

enum SoundLibraryError: LocalizedError {
    case unsupported(String)
    case convertFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let ext): return "対応していない形式です: .\(ext)"
        case .convertFailed(let msg): return "変換に失敗しました: \(msg)"
        }
    }
}

/// アラーム音(AlarmKit用)と大当たりBGM(AVAudioPlayer用)のファイル管理。
/// - アラーム音: Library/Sounds/ に保存(WWDC25で案内された置き場所。実機で鳴るか検証する)
/// - BGM:       Application Support/PachiAlarm/BGM/ に保存
enum SoundLibrary {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "caf", "aif", "aiff"]
    /// 取り込んだアラーム音の名前の先頭に付ける(同梱音と名前が被らないように)
    static let importedPrefix = "u_"
    static let bundledBGMName = "dummy_bgm_30s.mp3"

    static var librarySoundsDir: URL {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return lib.appendingPathComponent("Sounds", isDirectory: true)
    }

    static var bgmDir: URL {
        SettingsStore.directory.appendingPathComponent("BGM", isDirectory: true)
    }

    static func ensureDirectories() {
        for dir in [librarySoundsDir, bgmDir] where !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        }
    }

    // MARK: - 一覧

    static func bundledSounds() -> [SoundItem] {
        guard let resURL = Bundle.main.resourceURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: resURL.path) else { return [] }
        return names
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .filter { $0.hasPrefix("dummy_alarm") }
            .sorted()
            .map { SoundItem(name: $0, location: .bundle, duration: duration(of: resURL.appendingPathComponent($0))) }
    }

    static func librarySounds() -> [SoundItem] { items(in: librarySoundsDir, location: .librarySounds) }

    static func bgmFiles() -> [SoundItem] { items(in: bgmDir, location: .bgm) }

    private static func items(in dir: URL, location: SoundItem.Location) -> [SoundItem] {
        ensureDirectories()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names
            .filter { audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
            .map { SoundItem(name: $0, location: location, duration: duration(of: dir.appendingPathComponent($0))) }
    }

    static func url(for item: SoundItem) -> URL? {
        switch item.location {
        case .bundle: return Bundle.main.resourceURL?.appendingPathComponent(item.name)
        case .librarySounds: return librarySoundsDir.appendingPathComponent(item.name)
        case .bgm: return bgmDir.appendingPathComponent(item.name)
        }
    }

    /// 設定のBGM名から実ファイルを決める。見つからなければ同梱ダミーにフォールバック。
    static func resolveBGM(_ name: String) -> URL? {
        if !name.isEmpty {
            let url = bgmDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
            DebugLog.shared.log("BGM", "選択中のBGMが見つからないため同梱ダミーを使います: \(name)")
        }
        return Bundle.main.url(forResource: bundledBGMName, withExtension: nil)
    }

    /// ファンファーレ音の名前から実ファイルを探す。取り込んだ音(Library/Sounds) → 同梱の順。
    /// 名前が空なら同梱の dummy_alarm_20s.caf を使う。
    static func resolveFanfare(_ name: String) -> URL? {
        let target = name.isEmpty ? "dummy_alarm_20s.caf" : name
        let lib = librarySoundsDir.appendingPathComponent(target)
        if FileManager.default.fileExists(atPath: lib.path) { return lib }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent(target),
           FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        return nil
    }

    static func duration(of url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    // MARK: - 取り込み

    /// アラーム音を取り込む。元ファイルのコピーと、CAF(16bit PCM)への変換版の2つを作る。
    /// どちらがAlarmKitで鳴るかを実機で比べるため。
    @discardableResult
    static func importAlarmSound(from src: URL) throws -> [String] {
        ensureDirectories()
        let ext = src.pathExtension.lowercased()
        guard audioExtensions.contains(ext) else { throw SoundLibraryError.unsupported(ext) }
        let base = importedPrefix + sanitize(src.deletingPathExtension().lastPathComponent)
        var messages: [String] = []

        // 1) 元形式のままコピー
        let copyURL = librarySoundsDir.appendingPathComponent("\(base).\(ext)")
        try replaceCopy(from: src, to: copyURL)
        let d1 = duration(of: copyURL)
        messages.append("コピー: \(copyURL.lastPathComponent) (\(format(d1)))")

        // 2) CAF(16bit PCM)へ変換
        if ext != "caf" {
            let cafURL = librarySoundsDir.appendingPathComponent("\(base)_pcm.caf")
            do {
                let d2 = try convertToPCMCaf(src: copyURL, dst: cafURL)
                messages.append("変換: \(cafURL.lastPathComponent) (\(format(d2)))")
            } catch {
                messages.append("変換失敗: \(error.localizedDescription)")
            }
        }

        if let d = d1, d >= 30 {
            messages.append("⚠️ 30秒以上あります。AlarmKitでは鳴らない・途中で切れる可能性があります(検証対象)")
        }
        messages.forEach { DebugLog.shared.log("IMPORT", $0) }
        return messages
    }

    @discardableResult
    static func importBGM(from src: URL) throws -> String {
        ensureDirectories()
        let ext = src.pathExtension.lowercased()
        guard audioExtensions.contains(ext) else { throw SoundLibraryError.unsupported(ext) }
        let name = sanitize(src.deletingPathExtension().lastPathComponent) + "." + ext
        let dst = bgmDir.appendingPathComponent(name)
        try replaceCopy(from: src, to: dst)
        let msg = "BGM取り込み: \(name) (\(format(duration(of: dst))))"
        DebugLog.shared.log("IMPORT", msg)
        return name
    }

    static func delete(_ item: SoundItem) throws {
        guard item.location != .bundle, let url = url(for: item) else { return }
        try FileManager.default.removeItem(at: url)
        DebugLog.shared.log("SOUND", "削除: \(item.name)")
    }

    // MARK: - 内部処理

    private static func replaceCopy(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: src, to: dst)
    }

    /// mp3/m4a/wav などを 16bit リニアPCM の CAF に変換する
    private static func convertToPCMCaf(src: URL, dst: URL) throws -> Double {
        let input = try AVAudioFile(forReading: src)
        let format = input.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        if FileManager.default.fileExists(atPath: dst.path) {
            try FileManager.default.removeItem(at: dst)
        }
        do {
            let output = try AVAudioFile(forWriting: dst, settings: settings,
                                         commonFormat: format.commonFormat,
                                         interleaved: format.isInterleaved)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else {
                throw SoundLibraryError.convertFailed("バッファを作れませんでした")
            }
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
        } // ここで output が解放され、ファイルが閉じられる
        return duration(of: dst) ?? 0
    }

    /// AlarmKitの .named() で確実に扱えるよう、英数字と - _ だけにする
    static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        if trimmed.isEmpty { return "sound_\(Int(Date().timeIntervalSince1970))" }
        return String(trimmed.prefix(40))
    }

    private static func format(_ d: Double?) -> String {
        guard let d = d else { return "長さ不明" }
        return String(format: "%.1f秒", d)
    }
}
