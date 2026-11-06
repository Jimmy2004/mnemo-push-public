import Foundation
import Darwin
import MnemoCore

// mnemo-e2e：本机 mnemosyne gateway（默认 127.0.0.1:8723）增量同步端到端检查。
//
// 流程：ping → 顺序跑 N 轮同步 → 读取每轮新写入队列文件的 NDJSON → 校验
//   1) 每轮来源计数，以及批内 (sourceType,id) 唯一
//   2) 跨批次转录不重复（转录按 sinceId 增量；其它来源按时间窗重复拉取，属设计预期）
//   3) device 字段与 --device 完全一致
//   4) transcript cursor 单调不减
// 若配置了推送，队列会被推送消费、无法逐条检查，此时只校验 cursor 并在输出中说明。
// 输出：stdout 逐行明细 + 机器可读的 MNEMO_E2E_SUMMARY 行；错误写 stderr 且退出码非 0。

// MARK: - 输出

func out(_ line: String) { print(line) }

func err(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

func check(_ name: String, _ ok: Bool, _ detail: String) {
    out("mnemo-e2e: CHECK \(name) \(ok ? "PASS" : "FAIL") \(detail)")
}

func note(_ name: String, _ detail: String) {
    out("mnemo-e2e: NOTE \(name) \(detail)")
}

// MARK: - 错误

enum E2EError: Error {
    case usage(String)
    case failed(String)

    var message: String {
        switch self {
        case .usage(let m), .failed(let m): return m
        }
    }

    var isUsage: Bool {
        if case .usage = self { return true }
        return false
    }
}

// MARK: - 日志收集（Syncer 的 log 回调要求 @Sendable）

final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func drain() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let snapshot = lines
        lines = []
        return snapshot
    }
}

// MARK: - CLI

struct Options {
    var token = ""
    var port = 8723
    var pushURL = ""
    var pushKey = ""
    var device = ""
    var hasDevice = false
    var days = 0
    var rounds = 2
    var stateParent: String?
    var keepState = false
    var showHelp = false
}

let usageText = """
mnemo-e2e — 本机 mnemosyne gateway 增量同步端到端检查

用法：
  mnemo-e2e --token <tokenId.secret> [选项]

选项：
  --token <值>        必填。通行证，格式 tokenId.secret
  --port <n>          网关端口，默认 8723
  --push-url <url>    VPS 推送地址（必须 https:// 开头）
  --push-key <key>    VPS 推送密钥
  --device <名称>     设备标识；写进每条记录（字母数字 -_.，最多 32 位）
  --days <n>          首次拉取天数，0 = 全部历史，默认 0
  --rounds <n>        顺序执行的同步轮数，默认 2
  --state-dir <目录>  使用该尚不存在的目录作为状态目录
  --keep-state        保留状态目录（默认结束后删除），便于脚本检查队列
  -h, --help          显示本帮助

说明：
  * 首次 --days 0 拉全部历史转录；之后转录按 sinceId 增量，其它来源按时间窗重复拉取（预期重复）。
  * 队列目录为 <状态目录>/queue，文件为 NDJSON，每行一条记录。
  * 配置推送时队列会被消费，此时只校验 cursor 单调并输出说明。
  * stdout 打印 CHECK 行与一行 MNEMO_E2E_SUMMARY JSON；错误写 stderr，退出码非 0。
"""

func parseOptions(_ args: [String]) throws -> Options {
    var o = Options()
    var idx = 0
    while idx < args.count {
        var flag = args[idx]
        var inline: String?
        if let eq = flag.firstIndex(of: "=") {
            inline = String(flag[flag.index(after: eq)...])
            flag = String(flag[flag.startIndex..<eq])
        }
        idx += 1

        func nextValue(_ name: String) throws -> String {
            if let inline { return inline }
            guard idx < args.count else { throw E2EError.usage("选项 \(name) 缺少取值") }
            let v = args[idx]
            idx += 1
            return v
        }

        switch flag {
        case "-h", "--help":
            o.showHelp = true
        case "--token":
            o.token = try nextValue("--token")
        case "--port":
            let v = try nextValue("--port")
            guard let n = Int(v) else { throw E2EError.usage("--port 需要整数：\(v)") }
            o.port = n
        case "--push-url":
            o.pushURL = try nextValue("--push-url")
        case "--push-key":
            o.pushKey = try nextValue("--push-key")
        case "--device":
            o.device = try nextValue("--device")
            o.hasDevice = true
        case "--days":
            let v = try nextValue("--days")
            guard let n = Int(v) else { throw E2EError.usage("--days 需要整数：\(v)") }
            o.days = n
        case "--rounds":
            let v = try nextValue("--rounds")
            guard let n = Int(v) else { throw E2EError.usage("--rounds 需要整数：\(v)") }
            o.rounds = n
        case "--state-dir":
            o.stateParent = try nextValue("--state-dir")
        case "--keep-state":
            o.keepState = true
        default:
            throw E2EError.usage("未知选项：\(flag)")
        }
    }

    if o.showHelp { return o }
    let token = o.token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw E2EError.usage("缺少必填选项 --token") }
    guard let dot = token.firstIndex(of: "."), dot != token.startIndex,
          token.index(after: dot) != token.endIndex else {
        throw E2EError.usage("--token 格式应为 tokenId.secret")
    }
    o.token = token
    guard (1...65535).contains(o.port) else { throw E2EError.usage("--port 须为 1–65535") }
    guard (0...3650).contains(o.days) else { throw E2EError.usage("--days 须为 0–3650") }
    guard o.rounds >= 1 else { throw E2EError.usage("--rounds 须 ≥ 1") }
    if o.hasDevice {
        o.device = o.device.trimmingCharacters(in: .whitespacesAndNewlines)

    }
    o.pushURL = o.pushURL.trimmingCharacters(in: .whitespacesAndNewlines)
    o.pushKey = o.pushKey.trimmingCharacters(in: .whitespacesAndNewlines)
    return o
}

// MARK: - 状态目录

func childName() -> String {
    let stamp = String(Int64(Date().timeIntervalSince1970 * 1000))
    return "mnemo-e2e-\(stamp)-\(UUID().uuidString.prefix(8))"
}

/// 使用指定的新目录；省略时在系统临时目录中随机创建。
func makeStateDir(parent: String?) throws -> URL {
    let fm = FileManager.default
    let dir: URL
    if let parent, !parent.isEmpty {
        dir = URL(fileURLWithPath: (parent as NSString).expandingTildeInPath, isDirectory: true)
    } else {
        dir = fm.temporaryDirectory.appendingPathComponent(childName(), isDirectory: true)
    }
    guard !fm.fileExists(atPath: dir.path) else {
        throw E2EError.failed("状态目录必须尚不存在：\(dir.path)")
    }
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)

    return dir
}

// MARK: - 队列读取

/// 队列目录下的 NDJSON 文件名（排序后）。Syncer 的队列路径是私有实现，这里按其约定 <dir>/queue。
func queueFiles(_ queueDir: URL) -> [String] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: queueDir.path) else { return [] }
    return names.filter { $0.hasSuffix(".ndjson") }.sorted()
}

func itemsInFile(_ url: URL) throws -> [[String: Any]] {
    let data = try Data(contentsOf: url)
    let text = String(decoding: data, as: UTF8.self)
    var result: [[String: Any]] = []
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { continue }
        let any = try JSONSerialization.jsonObject(with: Data(line.utf8))
        guard let obj = any as? [String: Any] else { throw E2EError.failed("队列行必须是 JSON 对象") }
        result.append(obj)
    }
    return result
}

func sourceType(_ obj: [String: Any]) -> String {
    if let s = obj["sourceType"] as? String { return s }
    return ""
}

func itemID(_ obj: [String: Any]) -> String {
    if let n = obj["id"] as? NSNumber { return n.stringValue }
    if let s = obj["id"] as? String { return s }
    return ""
}

func isTranscript(_ type: String) -> Bool {
    let t = type.lowercased()
    return t == "transcript" || t == "transcripts"
}

func errorText(_ error: Error) -> String {
    if let e = error as? SyncException { return e.message }
    return error.localizedDescription
}

/// 任何可能包含凭据的文本都过一遍脱敏（复用 MnemoCore 的 RecentLog.safe）。
func sanitize(_ text: String, _ config: Config) -> String {
    RecentLog.safe(text, config: config)
}

func hostOf(_ urlString: String) -> String {
    URL(string: urlString)?.host ?? "?"
}

// MARK: - 主流程

func execute(config: Config, opts: Options, stateDir: URL) async throws -> Int32 {
    let queueDir = stateDir.appendingPathComponent("queue", isDirectory: true)
    let sink = LogSink()
    let syncer = Syncer(config: config, dir: stateDir, log: { sink.append($0) })

    var violations: [String] = []
    var rounds: [[String: Any]] = []

    out("mnemo-e2e: state_dir=\(stateDir.path)")
    out("mnemo-e2e: queue_dir=\(queueDir.path)")
    out("mnemo-e2e: gateway=127.0.0.1:\(config.gatewayPort) agent=\(config.agent) days=\(config.days) rounds=\(opts.rounds)")

    // ping 网关
    do {
        try await syncer.ping()
        check("gateway_ping", true, "127.0.0.1:\(config.gatewayPort)")
    } catch {
        throw E2EError.failed("gateway ping 失败：\(sanitize(errorText(error), config))")
    }

    var previousSince: Int64?
    var accumulatedTranscript: Set<String> = []
    var accumulatedNonTranscript: Set<String> = []

    var index = 0
    while index < opts.rounds {
        index += 1
        let before = queueFiles(queueDir)
        let result: SyncResult
        do {
            result = try await syncer.run()
        } catch {
            throw E2EError.failed("第 \(index) 轮同步失败：\(sanitize(errorText(error), config))")
        }
        let after = queueFiles(queueDir)
        let newFiles = after.filter { !before.contains($0) }

        out("mnemo-e2e: round \(index) pulled=\(result.pulled) pushed=\(result.pushed) pending=\(result.pending) since_id=\(result.sinceId) new_files=\(newFiles.count)")
        for line in sink.drain() { out("mnemo-e2e:   log \(line)") }

        var info: [String: Any] = [
            "round": index,
            "pulled": result.pulled,
            "pushed": result.pushed,
            "pending": result.pending,
            "since_id": result.sinceId,
            "new_files": newFiles.count,
            "queue_inspected": !config.hasPush
        ]

        let priorCursor = previousSince ?? 0
        // cursor 单调
        if let previous = previousSince {
            let monotonic = result.sinceId >= previous
            check("cursor_monotonic", monotonic, "since_id \(previous) -> \(result.sinceId)")
            if !monotonic { violations.append("第 \(index) 轮 cursor 回退：\(previous) -> \(result.sinceId)") }
            info["cursor_monotonic"] = monotonic
        } else {
            info["cursor_monotonic"] = true
        }
        previousSince = result.sinceId

        if config.hasPush {
            note("queue_inspect", "已配置推送，队列被推送消费、无法逐条检查，仅校验 cursor 单调")
            info["sources"] = [String: Int]()
            info["items"] = 0
            info["unique_keys"] = 0
            info["duplicate_keys"] = 0
            info["transcript_repeats"] = 0
            info["nontranscript_repeats"] = 0
            info["device_check"] = "skipped"
        } else {
            var items: [[String: Any]] = []
            for file in newFiles {
                items += try itemsInFile(queueDir.appendingPathComponent(file))
            }

            var counts: [String: Int] = [:]
            var batchKeys: Set<String> = []
            var duplicateKeys = 0
            var missingType = 0
            var transcriptRepeats = 0
            var nonTranscriptRepeats = 0
            var deviceMismatch = 0
            var deviceMissing = 0

            let previousTranscript = accumulatedTranscript
            let previousNonTranscript = accumulatedNonTranscript

            for item in items {
                let type = sourceType(item)
                let id = itemID(item)
                if type.isEmpty || id.isEmpty { missingType += 1 }
                counts[type, default: 0] += 1
                let key = type + "\u{1}" + id
                if batchKeys.contains(key) { duplicateKeys += 1 }
                batchKeys.insert(key)
                if isTranscript(type) {
                    if let rid = Int64(id), rid > priorCursor, rid <= result.sinceId {} else {
                        violations.append("第 \(index) 轮 transcript ID 超出增量游标范围")
                    }
                    if previousTranscript.contains(key) { transcriptRepeats += 1 }
                    accumulatedTranscript.insert(key)
                } else {
                    if previousNonTranscript.contains(key) { nonTranscriptRepeats += 1 }
                    accumulatedNonTranscript.insert(key)
                }
                do {
                    if let dev = item["device"] as? String {
                        if dev != opts.device { deviceMismatch += 1 }
                    } else if !opts.device.isEmpty {
                        deviceMissing += 1
                    }
                }
            }

            let transcriptIDs = items.filter { isTranscript(sourceType($0)) }.compactMap { Int64(itemID($0)) }
            let expectedCursor = transcriptIDs.max() ?? priorCursor
            if result.sinceId != expectedCursor {
                violations.append("第 \(index) 轮游标与入队 transcript 最大 ID 不一致")
            }
            let summary = counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " ")
            out("mnemo-e2e:   sources \(summary.isEmpty ? "(none)" : summary)")

            let uniqueOK = duplicateKeys == 0
            check("batch_unique_keys", uniqueOK, "unique=\(batchKeys.count)/\(items.count) duplicates=\(duplicateKeys)")
            if !uniqueOK { violations.append("第 \(index) 轮批内 (sourceType,id) 重复 \(duplicateKeys) 个") }

            let hasType = missingType == 0
            check("source_type_present", hasType, "missing=\(missingType)")
            if !hasType { violations.append("第 \(index) 轮有 \(missingType) 条记录缺少 sourceType/id，无法校验增量") }

            let noTranscriptRepeat = transcriptRepeats == 0
            check("cross_batch_transcript_no_repeat", noTranscriptRepeat,
                  "repeats=\(transcriptRepeats) nontranscript_repeats=\(nonTranscriptRepeats)（非转录重复属预期）")
            if !noTranscriptRepeat { violations.append("第 \(index) 轮跨批次转录重复 \(transcriptRepeats) 条（转录应按 sinceId 增量）") }

            let pulledMatch = items.count == result.pulled
            check("queue_matches_pulled", pulledMatch, "queue=\(items.count) pulled=\(result.pulled)")
            if !pulledMatch { violations.append("第 \(index) 轮队列条数 \(items.count) 与 pulled \(result.pulled) 不一致") }

            do {
                let deviceOK = deviceMismatch == 0 && deviceMissing == 0
                check("device_exact", deviceOK, "device=\(opts.device) mismatch=\(deviceMismatch) missing=\(deviceMissing)")
                if !deviceOK { violations.append("第 \(index) 轮 device 不等于 \"\(opts.device)\"（mismatch=\(deviceMismatch) missing=\(deviceMissing)）") }
            }

            info["sources"] = counts
            info["items"] = items.count
            info["unique_keys"] = batchKeys.count
            info["duplicate_keys"] = duplicateKeys
            info["transcript_repeats"] = transcriptRepeats
            info["nontranscript_repeats"] = nonTranscriptRepeats
            info["device_check"] = (deviceMismatch == 0 && deviceMissing == 0 ? "exact" : "mismatch")
        }

        rounds.append(info)
    }

    // ping 推送（仅在配置了推送时）
    if config.hasPush {
        do {
            let ms = try await syncer.pingPush()
            check("push_ping", true, "latency=\(ms)ms host=\(hostOf(config.pushUrl))")
        } catch {
            throw E2EError.failed("push ping 失败：\(sanitize(errorText(error), config))")
        }
    } else {
        note("push_ping", "未配置 push，跳过")
    }

    let summary: [String: Any] = [
        "ok": violations.isEmpty,
        "state_dir": stateDir.path,
        "queue_dir": queueDir.path,
        "keep_state": opts.keepState,
        "push_configured": config.hasPush,
        "gateway_port": config.gatewayPort,
        "days": config.days,
        "rounds": rounds,
        "violations": violations
    ]
    if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]) {
        out("MNEMO_E2E_SUMMARY " + String(decoding: data, as: UTF8.self))
    }

    if violations.isEmpty {
        check("all_checks", true, "rounds=\(opts.rounds)")
        return 0
    }
    for v in violations { err("mnemo-e2e: violation: \(v)") }
    check("all_checks", false, "violations=\(violations.count)")
    return 1
}

func runCLI() async -> Int32 {
    var stateDir: URL?
    var keepState = false
    var configForSanitize: Config?
    var exitCode: Int32 = 1

    do {
        let opts = try parseOptions(Array(CommandLine.arguments.dropFirst()))
        if opts.showHelp {
            print(usageText)
            return 0
        }
        keepState = opts.keepState

        var config = Config()
        config.token = opts.token
        config.gatewayPort = opts.port
        config.days = opts.days
        config.device = opts.device
        config.pushUrl = opts.pushURL
        config.pushKey = opts.pushKey
        if opts.pushURL.isEmpty != opts.pushKey.isEmpty {
            throw E2EError.usage("--push-url 和 --push-key 必须同时提供")
        }
        let validated = try config.validated()
        configForSanitize = validated

        let dir = try makeStateDir(parent: opts.stateParent)
        stateDir = dir
        exitCode = try await execute(config: validated, opts: opts, stateDir: dir)
    } catch let e as E2EError {
        let text = configForSanitize.map { sanitize(e.message, $0) } ?? e.message
        err("mnemo-e2e: error: \(text)")
        exitCode = e.isUsage ? 2 : 1
    } catch let e as SyncException {
        let text = configForSanitize.map { sanitize(e.message, $0) } ?? e.message
        err("mnemo-e2e: error: \(text)")
        exitCode = 1
    } catch {
        let text = configForSanitize.map { sanitize(errorText(error), $0) } ?? errorText(error)
        err("mnemo-e2e: error: \(text)")
        exitCode = 1
    }

    if let dir = stateDir, !keepState {
        try? FileManager.default.removeItem(at: dir)
    }
    return exitCode
}

let status = await runCLI()
exit(status)
