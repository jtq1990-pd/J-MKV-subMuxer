import Cocoa
import WebKit
import UniformTypeIdentifiers

let appName = "J-MKV-subMuxer"
let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "m4v", "avi", "webm", "ts", "m2ts"]
let subtitleExtensions: Set<String> = ["srt", "ass", "ssa", "sup", "sub", "idx", "vtt"]

struct SubtitleTrack {
    let path: String
    var language: String
    var title: String
    var defaultTrack: Bool
}

struct MuxTask {
    let id: String
    let video: String
    var output: String
    var tracks: [SubtitleTrack]
    var status: String
    var progress: Int
    var phase: String
    var log: [String]
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var tasks: [MuxTask] = []
    private var isRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.add(self, name: "native")
        config.userContentController = userContent

        webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = appName
        window.contentView = webView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        webView.loadHTMLString(html, baseURL: Bundle.main.resourceURL)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            let body = message.body as? [String: Any],
            let id = body["id"] as? String,
            let action = body["action"] as? String
        else {
            return
        }
        let payload = body["payload"] as? [String: Any] ?? [:]

        switch action {
        case "status":
            reply(id, ok: true, payload: statusPayload())
        case "chooseManualTask":
            chooseManualTask(id: id, payload: payload)
        case "chooseVideos":
            chooseVideos(id: id, payload: payload)
        case "chooseFolders":
            chooseFolders(id: id, payload: payload)
        case "addSubtitlesToTask":
            addSubtitlesToTask(id: id, payload: payload)
        case "removeTask":
            removeTask(id: id, payload: payload)
        case "clearTasks":
            tasks.removeAll()
            reply(id, ok: true, payload: ["tasks": taskPayloads()])
        case "startAll":
            startAll(id: id, payload: payload)
        case "revealOutput":
            revealOutput(id: id, payload: payload)
        case "cleanupCompletedSources":
            cleanupCompletedSources(id: id)
        default:
            reply(id, ok: false, payload: ["error": "未知操作：\(action)"])
        }
    }

    private func statusPayload() -> [String: Any] {
        [
            "engine": bundledTool("mkvmerge")?.path ?? "",
            "ffmpeg": bundledTool("ffmpeg")?.path ?? "",
            "taskCount": tasks.count,
            "appContainer": "WKWebView"
        ]
    }

    private func chooseManualTask(id: String, payload: [String: Any]) {
        guard let video = openFiles(title: "选择一个视频文件", allowed: Array(videoExtensions), multiple: false).first else {
            reply(id, ok: false, payload: ["error": "未选择视频文件。"])
            return
        }
        guard let subtitles = optionalOpenFiles(title: "选择该视频对应的字幕文件", allowed: Array(subtitleExtensions), multiple: true), !subtitles.isEmpty else {
            reply(id, ok: false, payload: ["error": "未选择字幕文件。"])
            return
        }
        let language = normalizedLanguage(payload["language"] as? String ?? "chi")
        var tracks = subtitles.enumerated().map { index, path in
            SubtitleTrack(
                path: path,
                language: language,
                title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                defaultTrack: index == 0
            )
        }
        if !(payload["firstDefault"] as? Bool ?? true) {
            tracks = tracks.map { SubtitleTrack(path: $0.path, language: $0.language, title: $0.title, defaultTrack: false) }
        }
        tasks.append(makeTask(video: video, tracks: tracks))
        reply(id, ok: true, payload: ["tasks": taskPayloads()])
    }

    private func chooseVideos(id: String, payload: [String: Any]) {
        let selected = openFiles(title: "选择一个或多个视频文件", allowed: Array(videoExtensions), multiple: true)
        if selected.isEmpty {
            reply(id, ok: false, payload: ["error": "未选择视频文件。"])
            return
        }
        let language = normalizedLanguage(payload["language"] as? String ?? "chi")
        let firstDefault = payload["firstDefault"] as? Bool ?? true
        var warnings: [String] = []
        for video in selected {
            let tracks = autoTracksForVideo(video, language: language, firstDefault: firstDefault)
            if tracks.isEmpty {
                warnings.append("未在同目录识别到字幕：\(URL(fileURLWithPath: video).lastPathComponent)")
            }
            tasks.append(makeTask(video: video, tracks: tracks))
        }
        reply(id, ok: true, payload: ["tasks": taskPayloads(), "warnings": warnings])
    }

    private func chooseFolders(id: String, payload: [String: Any]) {
        let folders = openFolders(title: "选择一个或多个包含视频和字幕的文件夹", multiple: true)
        if folders.isEmpty {
            reply(id, ok: false, payload: ["error": "未选择文件夹。"])
            return
        }
        let language = normalizedLanguage(payload["language"] as? String ?? "chi")
        let firstDefault = payload["firstDefault"] as? Bool ?? true
        let recursive = payload["recursive"] as? Bool ?? true
        let result = tasksFromFolders(folders, language: language, firstDefault: firstDefault, recursive: recursive)
        tasks.append(contentsOf: result.tasks)
        reply(id, ok: true, payload: ["tasks": taskPayloads(), "warnings": result.warnings])
    }

    private func addSubtitlesToTask(id: String, payload: [String: Any]) {
        guard let taskId = payload["taskId"] as? String, let index = tasks.firstIndex(where: { $0.id == taskId }) else {
            reply(id, ok: false, payload: ["error": "任务不存在。"])
            return
        }
        guard let selected = optionalOpenFiles(title: "选择要追加的字幕文件", allowed: Array(subtitleExtensions), multiple: true), !selected.isEmpty else {
            reply(id, ok: false, payload: ["error": "未选择字幕文件。"])
            return
        }
        let language = normalizedLanguage(payload["language"] as? String ?? "chi")
        let known = Set(tasks[index].tracks.map { $0.path })
        var newTracks = tasks[index].tracks
        for path in selected where !known.contains(path) {
            newTracks.append(SubtitleTrack(
                path: path,
                language: language,
                title: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                defaultTrack: newTracks.isEmpty
            ))
        }
        tasks[index].tracks = normalizeDefaultTrack(newTracks, firstDefault: payload["firstDefault"] as? Bool ?? true)
        tasks[index].status = "ready"
        reply(id, ok: true, payload: ["tasks": taskPayloads()])
    }

    private func removeTask(id: String, payload: [String: Any]) {
        guard let taskId = payload["taskId"] as? String else {
            reply(id, ok: false, payload: ["error": "缺少任务 ID。"])
            return
        }
        tasks.removeAll { $0.id == taskId }
        reply(id, ok: true, payload: ["tasks": taskPayloads()])
    }

    private func startAll(id: String, payload: [String: Any]) {
        if isRunning {
            reply(id, ok: false, payload: ["error": "已有批量任务正在运行。"])
            return
        }
        guard !tasks.isEmpty else {
            reply(id, ok: false, payload: ["error": "当前没有任务。"])
            return
        }
        guard bundledTool("mkvmerge") != nil else {
            reply(id, ok: false, payload: ["error": "App 内未找到 mkvmerge。请重新安装 DMG。"])
            return
        }

        let keepExisting = payload["keepExisting"] as? Bool ?? true
        isRunning = true
        reply(id, ok: true, payload: ["tasks": taskPayloads()])

        DispatchQueue.global(qos: .userInitiated).async {
            for taskIndex in self.tasks.indices {
                if self.tasks[taskIndex].tracks.isEmpty {
                    self.updateTask(taskIndex, status: "failed", appendLog: "错误：该任务没有字幕文件。", progress: 0, phase: "缺少字幕")
                    continue
                }
                self.runMuxTask(index: taskIndex, keepExisting: keepExisting)
            }
            DispatchQueue.main.async {
                self.isRunning = false
                self.emit(event: "allDone", payload: ["tasks": self.taskPayloads()])
            }
        }
    }

    private func revealOutput(id: String, payload: [String: Any]) {
        guard let taskId = payload["taskId"] as? String, let task = tasks.first(where: { $0.id == taskId }) else {
            reply(id, ok: false, payload: ["error": "任务不存在。"])
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: task.output)])
        reply(id, ok: true, payload: [:])
    }

    private func cleanupCompletedSources(id: String) {
        if isRunning {
            reply(id, ok: false, payload: ["error": "任务运行中，不能清理源文件。"])
            return
        }

        let completedIndexes = tasks.indices.filter { tasks[$0].status == "done" || tasks[$0].status == "warning" }
        guard !completedIndexes.isEmpty else {
            reply(id, ok: false, payload: ["error": "没有已完成任务可清理。"])
            return
        }

        let fm = FileManager.default
        let outputPaths = Set(tasks.map { URL(fileURLWithPath: $0.output).standardizedFileURL.path })
        var sourcePaths = Set<String>()

        for index in completedIndexes {
            let task = tasks[index]
            let outputURL = URL(fileURLWithPath: task.output)
            guard fm.fileExists(atPath: outputURL.path),
                  let attributes = try? fm.attributesOfItem(atPath: outputURL.path),
                  let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0
            else {
                tasks[index].log.append("清理已跳过：输出 MKV 不存在或为空。")
                continue
            }

            sourcePaths.insert(URL(fileURLWithPath: task.video).standardizedFileURL.path)
            for track in task.tracks {
                sourcePaths.insert(URL(fileURLWithPath: track.path).standardizedFileURL.path)
            }
        }

        sourcePaths.subtract(outputPaths)

        var deleted: [String] = []
        var failed: [String] = []
        for path in sourcePaths.sorted() {
            let url = URL(fileURLWithPath: path)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                var trashedURL: NSURL?
                try fm.trashItem(at: url, resultingItemURL: &trashedURL)
                deleted.append(path)
            } catch {
                failed.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        for index in completedIndexes {
            if !deleted.isEmpty {
                tasks[index].log.append("已清理源文件：\(deleted.count) 个文件已移到废纸篓。")
            }
            if !failed.isEmpty {
                tasks[index].log.append("清理有失败：\(failed.joined(separator: "；"))")
            }
        }

        reply(id, ok: true, payload: [
            "deletedCount": deleted.count,
            "failed": failed,
            "tasks": taskPayloads()
        ])
    }

    private func runMuxTask(index: Int, keepExisting: Bool) {
        let task = tasks[index]
        let videoURL = URL(fileURLWithPath: task.video)
        let outputURL = URL(fileURLWithPath: task.output)
        let tempURL = outputURL.deletingLastPathComponent().appendingPathComponent(".\(outputURL.deletingPathExtension().lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier).mkv")

        updateTask(index, status: "running", appendLog: "开始封装：\(videoURL.lastPathComponent)", progress: 0, phase: "准备封装")

        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let mkvmerge = bundledTool("mkvmerge") else {
            updateTask(index, status: "failed", appendLog: "错误：App 内未找到 mkvmerge。", phase: "封装引擎缺失")
            return
        }

        var args = ["--ui-language", "en_US", "-o", tempURL.path]
        if !keepExisting {
            args.append("--no-subtitles")
        }
        args.append(task.video)
        for track in task.tracks {
            args += [
                "--language", "0:\(track.language)",
                "--track-name", "0:\(track.title)",
                "--default-track", "0:\(track.defaultTrack ? "yes" : "no")",
                track.path
            ]
        }

        updateTask(index, status: "running", appendLog: "封装命令已启动。", phase: "读取输入轨道")

        let process = Process()
        process.executableURL = mkvmerge
        process.arguments = args
        process.environment = [
            "PATH": "\(toolsBinURL().path):/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "en_US.UTF-8"
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            updateTask(index, status: "failed", appendLog: "错误：无法启动 mkvmerge：\(error.localizedDescription)", phase: "启动失败")
            return
        }

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { readable in
            let data = readable.availableData
            if !data.isEmpty {
                if let text = String(data: data, encoding: .utf8) {
                    self.consumeMuxOutput(text, index: index)
                }
            }
        }
        process.waitUntilExit()
        handle.readabilityHandler = nil

        let exitCode = process.terminationStatus

        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            updateTask(index, status: "failed", appendLog: "错误：mkvmerge 退出码 \(exitCode)，且未生成临时 MKV 文件。", phase: "未生成文件")
            return
        }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: tempURL.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.int64Value > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            updateTask(index, status: "failed", appendLog: "错误：mkvmerge 退出码 \(exitCode)，但临时 MKV 文件为空。", phase: "输出为空")
            return
        }

        guard exitCode == 0 || exitCode == 1 else {
            try? FileManager.default.removeItem(at: tempURL)
            updateTask(index, status: "failed", appendLog: "错误：mkvmerge 退出码 \(exitCode)。", phase: "封装失败")
            return
        }

        do {
            try FileManager.default.moveItem(at: tempURL, to: outputURL)
            if exitCode == 1 {
                updateTask(index, status: "warning", appendLog: "完成但有警告：文件已生成：\(outputURL.path)", progress: 100, phase: "完成-有警告")
            } else {
                updateTask(index, status: "done", appendLog: "完成：\(outputURL.path)", progress: 100, phase: "完成")
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            updateTask(index, status: "failed", appendLog: "错误：无法写入输出文件：\(error.localizedDescription)", phase: "写入失败")
        }
    }

    private func consumeMuxOutput(_ text: String, index: Int) {
        let lines = text
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if let progress = progressPercent(from: line) {
                updateTask(index, status: "running", progress: progress, phase: "封装中 \(progress)%")
                continue
            }

            if line.localizedCaseInsensitiveContains("cue entries") {
                updateTask(index, status: "running", appendLog: "正在写入 MKV 索引。", progress: 100, phase: "写入索引")
                continue
            }

            if line.localizedCaseInsensitiveContains("multiplexing took") {
                updateTask(index, status: "running", appendLog: "封装数据写入完成。", progress: 100, phase: "整理输出")
                continue
            }

            if line.localizedCaseInsensitiveContains("warning") {
                updateTask(index, status: "running", appendLog: "警告：\(line)", phase: "封装有警告")
                continue
            }

            if line.localizedCaseInsensitiveContains("error") {
                updateTask(index, status: "running", appendLog: "错误：\(line)", phase: "封装报错")
            }
        }
    }

    private func progressPercent(from line: String) -> Int? {
        guard let range = line.range(of: #"Progress:\s*([0-9]{1,3})%"#, options: .regularExpression) else {
            return nil
        }
        let match = String(line[range])
        let digits = match.filter { $0.isNumber }
        guard let value = Int(digits) else { return nil }
        return max(0, min(100, value))
    }

    private func updateTask(_ index: Int, status: String? = nil, appendLog: String? = nil, progress: Int? = nil, phase: String? = nil) {
        DispatchQueue.main.async {
            guard self.tasks.indices.contains(index) else { return }
            if let status {
                self.tasks[index].status = status
            }
            if let progress {
                self.tasks[index].progress = max(0, min(100, progress))
            }
            if let phase {
                self.tasks[index].phase = phase
            }
            if let appendLog, !appendLog.isEmpty, self.tasks[index].log.last != appendLog {
                self.tasks[index].log.append(appendLog)
            }
            self.emit(event: "tasksChanged", payload: ["tasks": self.taskPayloads()])
        }
    }

    private func makeTask(video: String, tracks: [SubtitleTrack]) -> MuxTask {
        let videoURL = URL(fileURLWithPath: video)
        let output = videoURL.deletingPathExtension().path + "_mkv封装.mkv"
        let status = tracks.isEmpty ? "missingSubtitles" : "ready"
        return MuxTask(
            id: UUID().uuidString,
            video: video,
            output: output,
            tracks: tracks,
            status: status,
            progress: 0,
            phase: tracks.isEmpty ? "等待补充字幕" : "等待封装",
            log: tracks.isEmpty ? ["未识别到字幕文件，可点击“加字幕”手动追加。"] : ["已识别字幕 \(tracks.count) 个。"]
        )
    }

    private func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    private func isGeneratedOutputVideo(_ url: URL) -> Bool {
        isVideoFile(url) && url.deletingPathExtension().lastPathComponent.hasSuffix("_mkv封装")
    }

    private func isBatchSourceVideo(_ url: URL) -> Bool {
        isVideoFile(url) && !isGeneratedOutputVideo(url)
    }

    private func tasksFromFolders(_ folders: [String], language: String, firstDefault: Bool, recursive: Bool) -> (tasks: [MuxTask], warnings: [String]) {
        var result: [MuxTask] = []
        var warnings: [String] = []
        let fm = FileManager.default

        for folder in folders {
            let folderURL = URL(fileURLWithPath: folder)
            var filesByDirectory: [String: [URL]] = [:]

            if recursive {
                if let enumerator = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                    for case let url as URL in enumerator {
                        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                            filesByDirectory[url.deletingLastPathComponent().path, default: []].append(url)
                        }
                    }
                }
            } else if let urls = try? fm.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
                filesByDirectory[folderURL.path] = urls.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            }

            for (_, files) in filesByDirectory {
                let videos = files.filter { isBatchSourceVideo($0) }
                let subtitles = files.filter { subtitleExtensions.contains($0.pathExtension.lowercased()) }
                if videos.isEmpty {
                    continue
                }
                for video in videos {
                    let tracks = matchSubtitles(video: video, videosInDirectory: videos, subtitles: subtitles, language: language, firstDefault: firstDefault)
                    if tracks.isEmpty {
                        warnings.append("跳过未匹配字幕的视频：\(video.lastPathComponent)")
                        continue
                    }
                    result.append(makeTask(video: video.path, tracks: tracks))
                }
            }
        }

        return (result, warnings)
    }

    private func autoTracksForVideo(_ video: String, language: String, firstDefault: Bool) -> [SubtitleTrack] {
        let videoURL = URL(fileURLWithPath: video)
        let dir = videoURL.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        let videos = files.filter { isBatchSourceVideo($0) }
        let subtitles = files.filter { subtitleExtensions.contains($0.pathExtension.lowercased()) }
        return matchSubtitles(video: videoURL, videosInDirectory: videos, subtitles: subtitles, language: language, firstDefault: firstDefault)
    }

    private func matchSubtitles(video: URL, videosInDirectory: [URL], subtitles: [URL], language: String, firstDefault: Bool) -> [SubtitleTrack] {
        let videoStem = video.deletingPathExtension().lastPathComponent.lowercased()
        var matched = subtitles.filter { subtitle in
            let stem = subtitle.deletingPathExtension().lastPathComponent.lowercased()
            return stem == videoStem
                || stem.hasPrefix(videoStem + ".")
                || stem.hasPrefix(videoStem + "_")
                || stem.hasPrefix(videoStem + "-")
                || stem.hasPrefix(videoStem + " ")
                || stem.hasPrefix(videoStem + "[")
        }
        if videosInDirectory.count == 1 && matched.isEmpty {
            matched = subtitles
        }
        matched.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return normalizeDefaultTrack(matched.enumerated().map { index, url in
            SubtitleTrack(
                path: url.path,
                language: language,
                title: url.deletingPathExtension().lastPathComponent,
                defaultTrack: firstDefault && index == 0
            )
        }, firstDefault: firstDefault)
    }

    private func normalizeDefaultTrack(_ tracks: [SubtitleTrack], firstDefault: Bool) -> [SubtitleTrack] {
        tracks.enumerated().map { index, track in
            SubtitleTrack(
                path: track.path,
                language: track.language,
                title: track.title,
                defaultTrack: firstDefault && index == 0
            )
        }
    }

    private func normalizedLanguage(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.isEmpty { return "und" }
        let aliases = [
            "zh": "chi", "zho": "chi", "cn": "chi", "chs": "chi", "cht": "chi",
            "en": "eng", "jp": "jpn", "ja": "jpn", "kr": "kor", "ko": "kor"
        ]
        return aliases[value] ?? value
    }

    private func openFiles(title: String, allowed: [String], multiple: Bool) -> [String] {
        optionalOpenFiles(title: title, allowed: allowed, multiple: multiple) ?? []
    }

    private func optionalOpenFiles(title: String, allowed: [String], multiple: Bool) -> [String]? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = multiple
        panel.allowedContentTypes = allowed.compactMap { UTType(filenameExtension: $0) }
        let response = panel.runModal()
        guard response == .OK else { return nil }
        return panel.urls.map { $0.path }
    }

    private func openFolders(title: String, multiple: Bool) -> [String] {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = multiple
        let response = panel.runModal()
        guard response == .OK else { return [] }
        return panel.urls.map { $0.path }
    }

    private func taskPayloads() -> [[String: Any]] {
        tasks.map { task in
            [
                "id": task.id,
                "video": task.video,
                "videoName": URL(fileURLWithPath: task.video).lastPathComponent,
                "output": task.output,
                "outputName": URL(fileURLWithPath: task.output).lastPathComponent,
                "subtitleCount": task.tracks.count,
                "subtitles": task.tracks.map { URL(fileURLWithPath: $0.path).lastPathComponent },
                "status": task.status,
                "statusLabel": statusLabel(task.status),
                "progress": task.progress,
                "phase": task.phase,
                "log": task.log
            ]
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "ready": return "待处理"
        case "missingSubtitles": return "缺字幕"
        case "running": return "运行中"
        case "done": return "完成"
        case "warning": return "完成-有警告"
        case "failed": return "失败"
        default: return status
        }
    }

    private func bundledTool(_ name: String) -> URL? {
        let url = toolsBinURL().appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    private func toolsBinURL() -> URL {
        Bundle.main.resourceURL!.appendingPathComponent("Tools/bin")
    }

    private func reply(_ id: String, ok: Bool, payload: [String: Any]) {
        var data = payload
        if !ok && data["error"] == nil {
            data["error"] = "操作失败。"
        }
        let payloadJSON = jsonLiteral(data)
        let idJSON = jsonLiteral(id)
        webView.evaluateJavaScript("window.nativeReply(\(idJSON), \(ok ? "true" : "false"), \(payloadJSON));")
    }

    private func emit(event: String, payload: [String: Any]) {
        let eventJSON = jsonLiteral(event)
        let payloadJSON = jsonLiteral(payload)
        webView.evaluateJavaScript("window.nativeEvent(\(eventJSON), \(payloadJSON));")
    }

    private func jsonLiteral(_ value: Any) -> String {
        guard
            JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: []),
            let text = String(data: data, encoding: .utf8)
        else {
            return "null"
        }
        return text
    }

    private func jsonLiteral(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value], options: [])
        let arrayText = String(data: data, encoding: .utf8)!
        return String(arrayText.dropFirst().dropLast())
    }
}

let html = #"""
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>J-MKV-subMuxer</title>
  <style>
    :root {
      color-scheme: light;
      --page: #edf1f4;
      --ink: #16202b;
      --muted: #647181;
      --soft: #eef3f7;
      --panel: #ffffff;
      --panel-deep: #101923;
      --panel-deep-2: #172333;
      --line: #d7e0e8;
      --line-strong: #c2ced9;
      --cyan: #00a6c8;
      --cyan-dark: #087d96;
      --green: #167852;
      --red: #b42318;
      --amber: #9a5b00;
      --shadow: 0 18px 48px rgba(22, 32, 43, .12);
      --radius: 8px;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-width: 960px;
      background:
        linear-gradient(180deg, #f6f8fa 0, var(--page) 220px),
        var(--page);
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", Arial, sans-serif;
      letter-spacing: 0;
    }
    button, input { font: inherit; }
    button {
      height: 34px;
      border: 1px solid var(--line-strong);
      border-radius: 7px;
      padding: 0 12px;
      background: #f8fafc;
      color: #172333;
      font-size: 13px;
      font-weight: 720;
      cursor: pointer;
      white-space: nowrap;
    }
    button:hover { background: #edf3f7; }
    button:disabled { opacity: .48; cursor: not-allowed; }
    button.primary { background: var(--cyan); border-color: var(--cyan); color: #fff; }
    button.primary:hover { background: var(--cyan-dark); }
    button.danger { color: var(--red); border-color: #efc2bd; background: #fff7f6; }
    input[type="text"] {
      height: 34px;
      border: 1px solid var(--line-strong);
      border-radius: 7px;
      padding: 0 10px;
      background: #fff;
      color: var(--ink);
      font-size: 13px;
    }
    input.short { width: 86px; }
    .shell { width: min(1240px, calc(100vw - 36px)); margin: 18px auto 22px; }
    .topbar {
      display: flex;
      gap: 16px;
      align-items: center;
      justify-content: space-between;
      margin-bottom: 14px;
    }
    .brand {
      display: flex;
      gap: 14px;
      align-items: center;
      min-height: 104px;
      padding: 18px;
      border: 1px solid var(--line);
      border-radius: var(--radius);
      background: rgba(255,255,255,.88);
      box-shadow: var(--shadow);
      flex: 1;
      min-width: 0;
    }
    .mark {
      width: 66px;
      height: 66px;
      border-radius: 16px;
      display: block;
      object-fit: cover;
      background: #111922;
      border: 1px solid #364454;
      box-shadow: inset 0 1px 0 rgba(255,255,255,.12), 0 14px 26px rgba(16,25,35,.22);
    }
    .eyebrow {
      margin-bottom: 4px;
      color: var(--cyan-dark);
      font-size: 12px;
      font-weight: 860;
    }
    h1 { margin: 0; font-size: 25px; line-height: 1.12; }
    .subtitle { margin: 8px 0 0; color: var(--muted); font-size: 13px; line-height: 1.45; max-width: 760px; }
    .engine {
      height: 30px;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      padding: 0 12px;
      border: 1px solid #badbcc;
      border-radius: 999px;
      background: #f2fbf6;
      color: var(--green);
      font-size: 12px;
      font-weight: 860;
      cursor: help;
      flex: 0 0 auto;
    }
    .engine::before { content: ""; width: 7px; height: 7px; border-radius: 999px; background: currentColor; }
    .engine.missing { color: var(--red); border-color: #efc2bd; background: #fff7f6; }
    .engine-title { display: flex; justify-content: space-between; gap: 10px; align-items: center; margin-bottom: 8px; font-weight: 780; color: #fff; }
    .engine code { color: #9ee8f3; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 11px; word-break: break-all; }
    .layout {
      display: block;
    }
    aside {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 430px;
      gap: 14px;
      align-items: start;
      margin-bottom: 14px;
    }
    aside .panel + .panel { margin-top: 0; }
    .panel {
      border: 1px solid var(--line);
      border-radius: var(--radius);
      background: var(--panel);
      box-shadow: var(--shadow);
      overflow: hidden;
    }
    .panel + .panel { margin-top: 14px; }
    .panel-head {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
      min-height: 45px;
      padding: 12px 14px;
      border-bottom: 1px solid var(--line);
      background: #f8fafc;
      font-size: 14px;
      font-weight: 800;
    }
    .panel-body { padding: 14px; }
    .steps { display: grid; gap: 10px; }
    .step {
      display: grid;
      grid-template-columns: 28px minmax(0,1fr);
      gap: 10px;
      padding: 10px;
      border: 1px solid #dce5ed;
      border-radius: 8px;
      background: #fbfcfd;
    }
    .step-no {
      width: 28px;
      height: 28px;
      border-radius: 999px;
      display: grid;
      place-items: center;
      background: #e6f7fb;
      color: #057e98;
      font-size: 13px;
      font-weight: 850;
    }
    .step-title { font-size: 13px; font-weight: 780; }
    .step-text { margin-top: 2px; color: var(--muted); font-size: 12px; line-height: 1.45; }
    .form-grid { display: grid; gap: 12px; }
    .field-row { display: flex; align-items: center; gap: 10px; flex-wrap: wrap; }
    label.field-label { min-width: 90px; color: #2a3745; font-size: 13px; font-weight: 760; }
    .check {
      display: flex;
      align-items: flex-start;
      gap: 8px;
      color: #334155;
      font-size: 13px;
      line-height: 1.4;
    }
    .actions { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
    .actions button {
      width: 100%;
      height: auto;
      min-height: 70px;
      display: block;
      text-align: left;
      padding: 12px;
      line-height: 1.2;
    }
    .actions span { display: block; font-size: 15px; font-weight: 860; }
    .actions small { display: block; margin-top: 7px; color: var(--muted); font-size: 12px; line-height: 1.35; white-space: normal; font-weight: 560; }
    .actions .primary small { color: rgba(255,255,255,.82); }
    .hint { color: var(--muted); font-size: 12px; line-height: 1.45; }
    .notice-list { display: grid; gap: 8px; margin-top: 10px; }
    .notice {
      padding: 8px 10px;
      border-radius: 7px;
      border: 1px solid #dbe4ec;
      background: #f8fafc;
      color: #394657;
      font-size: 12px;
      line-height: 1.45;
    }
    .notice.error { border-color: #efc2bd; background: #fff7f6; color: var(--red); }
    .notice.warning { border-color: #f3d3a4; background: #fff9ed; color: var(--amber); }
    .notice.success { border-color: #b9dbc8; background: #f2fbf6; color: var(--green); }
    .summary {
      display: none;
      grid-template-columns: repeat(6, 1fr);
      gap: 8px;
      margin-bottom: 12px;
    }
    .stat {
      min-height: 66px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fff;
      padding: 10px;
    }
    .stat-value { font-size: 22px; line-height: 1; font-weight: 860; color: #15202b; }
    .stat-label { margin-top: 8px; color: var(--muted); font-size: 12px; font-weight: 680; }
    .queue-head {
      display: flex;
      justify-content: space-between;
      align-items: center;
      gap: 12px;
      margin-bottom: 10px;
    }
    .queue-title { font-size: 15px; font-weight: 850; }
    .queue-actions { display: flex; gap: 8px; align-items: center; }
    .task-list { display: grid; gap: 10px; }
    .empty-state {
      padding: 28px;
      border: 1px dashed #bfd0dc;
      border-radius: 8px;
      background: #f8fbfd;
      text-align: center;
    }
    .empty-title { font-size: 17px; font-weight: 850; }
    .empty-text { margin: 8px auto 16px; max-width: 560px; color: var(--muted); font-size: 13px; line-height: 1.5; }
    .empty-actions { display: flex; justify-content: center; gap: 8px; flex-wrap: wrap; }
    .task-card {
      display: grid;
      grid-template-columns: 96px minmax(0, 1fr) 150px;
      gap: 12px;
      align-items: center;
      padding: 12px;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fff;
    }
    .task-card.selected { border-color: #75cce0; box-shadow: 0 0 0 3px rgba(0,166,200,.13); }
    .badge {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      min-width: 78px;
      height: 24px;
      padding: 0 9px;
      border-radius: 999px;
      border: 1px solid var(--line);
      background: #fff;
      color: var(--muted);
      font-size: 12px;
      font-weight: 800;
    }
    .badge.ready { color: #255b94; border-color: #bbd7f2; background: #f2f8ff; }
    .badge.missingSubtitles, .badge.failed { color: var(--red); border-color: #f1c1bc; background: #fff7f6; }
    .badge.running, .badge.warning { color: var(--amber); border-color: #f4d19b; background: #fff8eb; }
    .badge.done { color: var(--green); border-color: #badbcc; background: #f2fbf6; }
    .task-main { min-width: 0; }
    .task-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 14px; font-weight: 800; color: #172333; }
    .task-meta { margin-top: 5px; display: flex; gap: 10px; align-items: center; min-width: 0; color: var(--muted); font-size: 12px; }
    .task-meta span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .progress-line { display: grid; grid-template-columns: minmax(0, 1fr) 42px; gap: 8px; align-items: center; margin-top: 9px; }
    .progress {
      height: 8px;
      border-radius: 999px;
      background: #e7edf3;
      overflow: hidden;
      border: 1px solid #d6e0e8;
    }
    .progress-fill {
      height: 100%;
      width: 0%;
      background: linear-gradient(90deg, #20bdd8, #0d879f);
      transition: width .18s ease;
    }
    .progress-value { color: #536171; font-size: 12px; font-weight: 760; text-align: right; }
    .task-actions { display: grid; grid-template-columns: 1fr 1fr; gap: 7px; }
    .task-actions button { height: 30px; padding: 0 8px; font-size: 12px; }
    .task-actions .wide { grid-column: span 2; }
    .detail {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 260px;
      gap: 12px;
    }
    .detail-card {
      border: 1px solid var(--line);
      border-radius: 8px;
      background: #fbfcfd;
      padding: 12px;
      min-width: 0;
    }
    .detail-title { font-size: 13px; font-weight: 850; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .detail-sub { margin-top: 5px; color: var(--muted); font-size: 12px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .log-box {
      height: 190px;
      overflow: auto;
      border: 1px solid #243345;
      border-radius: 8px;
      background: #101923;
      padding: 10px 12px;
      color: #dce7ef;
      font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
      font-size: 12px;
      line-height: 1.55;
    }
    .log-line { padding: 2px 0; white-space: pre-wrap; word-break: break-word; }
    .log-line.error { color: #ffb4aa; }
    .log-line.warning { color: #ffd18b; }
    .footer {
      display: flex;
      justify-content: space-between;
      gap: 14px;
      margin-top: 12px;
      color: var(--muted);
      font-size: 12px;
      line-height: 1.45;
    }
  </style>
</head>
<body>
  <main class="shell">
    <section class="topbar">
      <div class="brand">
        <img class="mark" src="app-icon-source.png" alt="J-MKV-subMuxer">
        <div>
          <div class="eyebrow">视频 + 字幕 -> MKV</div>
          <h1>J-MKV-subMuxer</h1>
          <p class="subtitle">把外部字幕封进 MKV。默认不转码、不烧录字幕，原画质保留，输出文件名追加 _mkv封装.mkv。</p>
        </div>
      </div>
      <div class="engine" id="engineBox">
        环境检查中
      </div>
    </section>

    <section class="layout">
      <aside>
        <section class="panel">
          <div class="panel-head">添加任务</div>
          <div class="panel-body">
            <div class="actions">
              <button class="primary" id="addFolders">
                <span>批量添加文件夹</span>
                <small>每个文件夹内放 1 个视频和对应字幕</small>
              </button>
              <button id="manualTask">
                <span>添加单个视频</span>
                <small>先选视频，再选要合并的字幕</small>
              </button>
            </div>
            <div class="notice-list" id="noticeList"></div>
          </div>
        </section>

        <section class="panel">
          <div class="panel-head">封装选项</div>
          <div class="panel-body">
            <div class="form-grid">
              <div class="field-row">
                <label class="field-label" for="language">字幕语言</label>
                <input id="language" class="short" type="text" value="chi">
                <span class="hint">中文 chi，英文 eng，日文 jpn，韩文 kor</span>
              </div>
              <label class="check"><input id="firstDefault" type="checkbox" checked> 首条字幕设为默认轨道</label>
              <label class="check"><input id="keepExisting" type="checkbox" checked> 保留原视频内置字幕</label>
              <label class="check"><input id="recursive" type="checkbox"> 添加文件夹时扫描子文件夹</label>
            </div>
          </div>
        </section>
      </aside>

      <section>
        <div class="summary">
          <div class="stat"><div class="stat-value" id="statTotal">0</div><div class="stat-label">全部任务</div></div>
          <div class="stat"><div class="stat-value" id="statReady">0</div><div class="stat-label">待处理</div></div>
          <div class="stat"><div class="stat-value" id="statRunning">0</div><div class="stat-label">运行中</div></div>
          <div class="stat"><div class="stat-value" id="statDone">0</div><div class="stat-label">已完成</div></div>
          <div class="stat"><div class="stat-value" id="statFailed">0</div><div class="stat-label">需处理</div></div>
          <div class="stat"><div class="stat-value" id="statProgress">0%</div><div class="stat-label">总体进度</div></div>
        </div>

        <section class="panel">
          <div class="panel-body">
            <div class="queue-head">
              <div>
                <div class="queue-title">任务队列</div>
                <div class="hint" id="queueHint">尚未添加任务。</div>
              </div>
              <div class="queue-actions">
                <button id="clearTasks">清空</button>
                <button class="primary" id="startAll">启动封装</button>
                <button class="danger" id="cleanupSources" title="二次确认后，把已完成任务的原视频和字幕移到废纸篓">只保留封装视频</button>
              </div>
            </div>
            <div class="task-list" id="taskList"></div>
          </div>
        </section>

        <section class="panel">
          <div class="panel-head">
            <span>执行详情</span>
            <span class="hint">点击队列中的任务查看详情</span>
          </div>
          <div class="panel-body">
            <div class="detail">
              <div class="detail-card">
                <div class="detail-title" id="detailTitle">未选择任务</div>
                <div class="detail-sub" id="detailOutput">添加任务后会显示输出文件。</div>
                <div class="progress-line">
                  <div class="progress"><div class="progress-fill" id="detailProgressFill"></div></div>
                  <div class="progress-value" id="detailProgressValue">0%</div>
                </div>
              </div>
              <div class="detail-card">
                <div class="detail-title" id="detailPhase">等待操作</div>
                <div class="detail-sub" id="detailSubtitles">字幕信息会显示在这里。</div>
              </div>
            </div>
            <div class="log-box" id="logBox" style="margin-top:12px"></div>
          </div>
        </section>
      </section>
    </section>

    <div class="footer">
      <span>文件夹规则：单视频文件夹使用该目录全部字幕；多视频文件夹按同名前缀匹配字幕。</span>
      <span>运行环境详情可悬停查看右上角标签。</span>
    </div>
  </main>

  <script>
    const state = { tasks: [], selectedTaskId: null, notices: [] };
    const pending = new Map();
    let counter = 0;
    const $ = (id) => document.getElementById(id);

    function callNative(action, payload = {}) {
      const id = "req_" + (++counter);
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
        window.webkit.messageHandlers.native.postMessage({ id, action, payload });
      });
    }

    window.nativeReply = (id, ok, payload) => {
      const entry = pending.get(id);
      if (!entry) return;
      pending.delete(id);
      ok ? entry.resolve(payload || {}) : entry.reject(new Error((payload && payload.error) || "操作失败"));
    };

    window.nativeEvent = (event, payload) => {
      if (event === "tasksChanged" || event === "allDone") {
        state.tasks = payload.tasks || [];
        render();
        if (event === "allDone") pushNotice("success", "封装队列已结束。失败或有警告的任务会保留在队列中。");
      }
    };

    function options() {
      return {
        language: $("language").value,
        firstDefault: $("firstDefault").checked,
        keepExisting: $("keepExisting").checked,
        recursive: $("recursive").checked
      };
    }

    function escapeHtml(value) {
      return String(value ?? "")
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll('"', "&quot;");
    }

    function pushNotice(type, text) {
      state.notices.unshift({ type, text });
      state.notices = state.notices.slice(0, 5);
      renderNotices();
    }

    function renderNotices() {
      const list = $("noticeList");
      list.innerHTML = state.notices.map(item => `<div class="notice ${escapeHtml(item.type)}">${escapeHtml(item.text)}</div>`).join("");
    }

    function counts() {
      const result = { total: state.tasks.length, ready: 0, running: 0, done: 0, failed: 0 };
      for (const task of state.tasks) {
        if (task.status === "ready") result.ready += 1;
        if (task.status === "running") result.running += 1;
        if (task.status === "done" || task.status === "warning") result.done += 1;
        if (task.status === "failed" || task.status === "missingSubtitles") result.failed += 1;
      }
      result.progress = result.total ? Math.round(state.tasks.reduce((sum, task) => sum + Number(task.progress || 0), 0) / result.total) : 0;
      return result;
    }

    function renderSummary() {
      const data = counts();
      $("statTotal").textContent = data.total;
      $("statReady").textContent = data.ready;
      $("statRunning").textContent = data.running;
      $("statDone").textContent = data.done;
      $("statFailed").textContent = data.failed;
      $("statProgress").textContent = data.progress + "%";
      $("queueHint").textContent = data.total
        ? `共 ${data.total} 个任务，${data.ready} 个待封装，${data.running} 个运行中，${data.done} 个已完成，${data.failed} 个需处理。`
        : "添加文件夹或单个视频后，任务会显示在这里。";
      $("startAll").disabled = data.total === 0 || data.running > 0;
      $("clearTasks").disabled = data.total === 0 || data.running > 0;
      $("cleanupSources").disabled = data.done === 0 || data.running > 0;
    }

    function renderTasks() {
      const list = $("taskList");
      if (!state.tasks.length) {
        state.selectedTaskId = null;
        list.innerHTML = `
          <div class="empty-state">
            <div class="empty-title">还没有任务</div>
            <div class="empty-text">批量处理时选择多个文件夹；单独处理时选择一个视频，再选择要合并进去的字幕文件。输出文件会和视频放在同一目录。</div>
            <div class="empty-actions">
              <button class="primary" data-empty-action="folders">批量添加文件夹</button>
              <button data-empty-action="manual">添加单个视频</button>
            </div>
          </div>
        `;
        renderDetail();
        return;
      }

      if (!state.selectedTaskId || !state.tasks.some(task => task.id === state.selectedTaskId)) {
        state.selectedTaskId = state.tasks[0].id;
      }

      list.innerHTML = state.tasks.map(task => {
        const progress = Math.max(0, Math.min(100, Number(task.progress || 0)));
        const selected = task.id === state.selectedTaskId ? " selected" : "";
        const subtitles = (task.subtitles || []).join(", ");
        const revealDisabled = (task.status === "done" || task.status === "warning") ? "" : " disabled";
        return `
          <div class="task-card${selected}" data-task-id="${escapeHtml(task.id)}">
            <div><span class="badge ${escapeHtml(task.status)}">${escapeHtml(task.statusLabel)}</span></div>
            <div class="task-main">
              <div class="task-title" title="${escapeHtml(task.video)}">${escapeHtml(task.videoName)}</div>
              <div class="task-meta">
                <span>${task.subtitleCount} 个字幕</span>
                <span title="${escapeHtml(subtitles)}">${escapeHtml(subtitles || "未匹配字幕")}</span>
                <span title="${escapeHtml(task.output)}">输出：${escapeHtml(task.outputName)}</span>
              </div>
              <div class="progress-line">
                <div class="progress"><div class="progress-fill" style="width:${progress}%"></div></div>
                <div class="progress-value">${progress}%</div>
              </div>
            </div>
            <div class="task-actions">
              <button data-action="addSub" data-id="${escapeHtml(task.id)}">加字幕</button>
              <button data-action="reveal" data-id="${escapeHtml(task.id)}"${revealDisabled}>定位</button>
              <button class="danger wide" data-action="remove" data-id="${escapeHtml(task.id)}">移除任务</button>
            </div>
          </div>
        `;
      }).join("");
      renderDetail();
    }

    function renderDetail() {
      const task = state.tasks.find(item => item.id === state.selectedTaskId);
      if (!task) {
        $("detailTitle").textContent = "未选择任务";
        $("detailOutput").textContent = "添加任务后会显示输出文件。";
        $("detailPhase").textContent = "等待操作";
        $("detailSubtitles").textContent = "字幕信息会显示在这里。";
        $("detailProgressFill").style.width = "0%";
        $("detailProgressValue").textContent = "0%";
        $("logBox").innerHTML = `<div class="log-line">等待添加任务。</div>`;
        return;
      }
      const progress = Math.max(0, Math.min(100, Number(task.progress || 0)));
      $("detailTitle").textContent = task.videoName;
      $("detailOutput").textContent = task.output;
      $("detailPhase").textContent = task.phase || task.statusLabel;
      $("detailSubtitles").textContent = `${task.subtitleCount} 个字幕：${(task.subtitles || []).join(", ") || "未匹配字幕"}`;
      $("detailProgressFill").style.width = progress + "%";
      $("detailProgressValue").textContent = progress + "%";
      const log = task.log && task.log.length ? task.log : ["暂无日志。"];
      $("logBox").innerHTML = log.map(line => {
        const cls = line.includes("错误") ? " error" : (line.includes("警告") ? " warning" : "");
        return `<div class="log-line${cls}">${escapeHtml(line)}</div>`;
      }).join("");
      $("logBox").scrollTop = $("logBox").scrollHeight;
    }

    function render() {
      renderSummary();
      renderTasks();
    }

    async function refreshStatus() {
      const data = await callNative("status");
      const ok = Boolean(data.engine);
      $("engineBox").textContent = ok ? "环境就绪" : "环境缺失";
      $("engineBox").classList.toggle("missing", !ok);
      $("engineBox").title = `容器：${data.appContainer || "WKWebView"}\nmkvmerge：${data.engine || "未找到"}\nffmpeg：${data.ffmpeg || "未找到"}`;
    }

    async function runAction(action, payload = {}) {
      try {
        const data = await callNative(action, payload);
        if (data.tasks) {
          state.tasks = data.tasks;
          render();
        }
        if (data.warnings && data.warnings.length) {
          data.warnings.forEach(line => pushNotice("warning", line));
        }
        if (data.failed && data.failed.length) {
          data.failed.forEach(line => pushNotice("warning", line));
        }
        if (action === "cleanupCompletedSources") {
          pushNotice("success", `已把 ${data.deletedCount || 0} 个源文件移到废纸篓。`);
        }
      } catch (error) {
        pushNotice("error", error.message);
      }
    }

    $("manualTask").addEventListener("click", () => runAction("chooseManualTask", options()));
    $("addFolders").addEventListener("click", () => runAction("chooseFolders", options()));
    $("clearTasks").addEventListener("click", () => runAction("clearTasks"));
    $("startAll").addEventListener("click", () => runAction("startAll", options()));
    $("cleanupSources").addEventListener("click", () => {
      const message = "确认只保留封装视频？\n\n已完成任务的原视频和字幕文件会移到废纸篓；生成的 _mkv封装.mkv 会保留。";
      if (window.confirm(message)) runAction("cleanupCompletedSources");
    });

    $("taskList").addEventListener("click", (event) => {
      const emptyAction = event.target.closest("[data-empty-action]");
      if (emptyAction) {
        const mode = emptyAction.dataset.emptyAction;
        if (mode === "folders") runAction("chooseFolders", options());
        if (mode === "manual") runAction("chooseManualTask", options());
        return;
      }

      const button = event.target.closest("button");
      const card = event.target.closest("[data-task-id]");
      if (card) {
        state.selectedTaskId = card.dataset.taskId;
        renderTasks();
      }
      if (!button || button.disabled) return;
      event.stopPropagation();
      const taskId = button.dataset.id;
      const action = button.dataset.action;
      if (action === "addSub") runAction("addSubtitlesToTask", { ...options(), taskId });
      if (action === "remove") runAction("removeTask", { taskId });
      if (action === "reveal") runAction("revealOutput", { taskId });
    });

    render();
    refreshStatus().catch(error => pushNotice("error", error.message));
  </script>
</body>
</html>
"""#

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
