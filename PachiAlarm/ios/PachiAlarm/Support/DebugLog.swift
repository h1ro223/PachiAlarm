import Foundation

/// Macのデバッガが使えないので、すべての検証結果をファイルに残す。
/// 保存先: Documents/phase0-log.txt(ファイルアプリ →「このiPhone内」→ PachiAlarm から見られる)
/// アプリ本体からも、停止ボタンのIntent(バックグラウンド起動)からも書き込む。
final class DebugLog {
    static let shared = DebugLog()

    let fileURL: URL
    private let queue = DispatchQueue(label: "com.h1ro223.pachialarm.log")
    private let maxBytes = 1_000_000

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "MM/dd HH:mm:ss.SSS"
        return f
    }()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("phase0-log.txt")
    }

    func log(_ tag: String, _ message: String) {
        let line = "[\(Self.formatter.string(from: Date()))] [\(tag)] \(message)\n"
        print(line, terminator: "")
        queue.async { [fileURL, maxBytes] in
            guard let data = line.data(using: .utf8) else { return }
            let fm = FileManager.default
            if !fm.fileExists(atPath: fileURL.path) {
                // ロック中(初回ロック解除後)でも書けるように保護レベルを指定
                fm.createFile(atPath: fileURL.path, contents: nil,
                              attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            }
            do {
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                if size > UInt64(maxBytes) {
                    // 大きくなりすぎたら後半だけ残す
                    try? handle.close()
                    if let old = try? Data(contentsOf: fileURL) {
                        let tail = old.suffix(maxBytes / 2)
                        try? (Data("…(古いログを削除)\n".utf8) + tail + data).write(to: fileURL)
                    }
                    return
                }
                try handle.write(contentsOf: data)
            } catch {
                print("DebugLog write error: \(error)")
            }
        }
    }

    /// 末尾から指定行数だけ読む(UI表示用)
    func readTail(lines: Int = 400) -> String {
        queue.sync {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return "(ログなし)" }
            let all = text.split(separator: "\n", omittingEmptySubsequences: false)
            return all.suffix(lines).joined(separator: "\n")
        }
    }

    func clear() {
        queue.sync {
            try? Data().write(to: fileURL)
        }
        log("LOG", "ログを消去しました")
    }
}
