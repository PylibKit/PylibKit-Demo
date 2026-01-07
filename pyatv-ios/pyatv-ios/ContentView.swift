//
//  ContentView.swift
//  pyatv-ios
//
//  Uses Pyatv.PyatvService.scan with the new AsyncioLoop helper from the xcframework.
//

import SwiftUI
import Combine
import PylibKit


@MainActor
final class PyatvViewModel: ObservableObject {
    enum RemoteAction {
        case playPause
        case next
        case previous
    }

    private enum WorkerEvent {
        case poll
        case remote(RemoteAction)
        case refresh
    }
    
    @Published var status: String = "Not initialized"
    @Published var devices: [Pyatv.Interface.BaseconfigInstance] = []
    @Published var deviceLabels: [String] = []
    @Published var connectionStatus: String = "Not connected"
    @Published var connectedName: String = "-"
    @Published var isReady: Bool = false
    @Published var isBusy: Bool = false
    @Published var isScanning: Bool = false
    @Published var hasRemoteControl: Bool = false
    @Published var logMessages: [String] = []
    @Published var lastError: String?
    @Published var hostOverride: String = ""
    @Published var nowPlayingTitle: String = ""
    @Published var nowPlayingSubtitle: String = ""
    @Published var nowPlayingPosition: Double = 0
    @Published var nowPlayingDuration: Double = 0
    
    private var cancellables = Set<AnyCancellable>()
    private let remoteCommandSubject = PassthroughSubject<RemoteAction, Never>()
    private let executor: PythonExecutor
    private var pyatvService: Pyatv.PyatvService?
    private var supportService: Pyatv.Support.SupportService?
    private var connectedAtv: Pyatv.Interface.AppletvInstance?
    private var connectedRemote: Pyatv.Interface.RemotecontrolInstance?
    private var connectedMetadata: Pyatv.Interface.MetadataInstance?
    private var lastConnectedDevice: Pyatv.Interface.BaseconfigInstance?
    private var lastConnectedLabel: String?
    private var workerTask: Task<Void, Never>?
    private var pollTimerTask: Task<Void, Never>?
    private var workerContinuation: AsyncStream<WorkerEvent>.Continuation?
    private var pollEnqueued = false
    private var nowPlayingPollCount = 0
    private var lastNowPlayingSignature: String = ""
    private var connectedProtocolLabel: String?
    private var isReconnectingAfterError = false
    private var isBootstrapInProgress = false
    // AirPlay metadata only updates for source streams; reconnect per poll as a workaround.
    private var useFreshNowPlayingConnection = true
    private var filterHomePodsOnly = true
    private var asyncioLoop: AsyncioLoop?
    private var storageInstance: Pyatv.Interface.StorageInstance?
    private var fileStorage: Pyatv.Storage.FileStorage.FilestorageInstance?
    private var memoryStorage: Pyatv.Storage.MemoryStorage.MemorystorageInstance?
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    init(executor: PythonExecutor) {
        self.executor = executor
        setupRemotePipeline()
    }
    
    func bootstrap(force: Bool = false) async {
        if (isReady && !force) || isBootstrapInProgress { return }
        isBootstrapInProgress = true
        isBusy = true
        status = "Configuring embedded Python..."
        lastError = nil
        
        await executor.installPythonLogForwarders(logLevel: .debug)
        pyatvService = await Pyatv.PyatvService.create(executor: executor)
        supportService = await Pyatv.Support.SupportService.create(executor: executor)
        _ = await ensureAsyncioLoop()
        
        status = "Ready"
        isReady = true
        appendLog("pyatv runtime loaded via wrappers")
        
        isBusy = false
        isBootstrapInProgress = false
    }
    
    func scan() {
        guard isReady, let service = pyatvService else {
            lastError = "Initialize runtime first."
            return
        }
        if isScanning { return }
        isScanning = true
        status = "Scanning for devices..."
        lastError = nil
        
        Task { @MainActor in
            // Always pass an asyncio loop so pyatv can bind sockets (required for mDNS).
            let loop = await ensureAsyncioLoop()
            let storage = await ensureStorage(loop: loop)
            // Pass nil so pyatv creates and drives its own Zeroconf browsers.
            // If we inject a pre-created aiozc, pyatv expects us to run ServiceBrowser
            // instances for every service type, otherwise the cache stays empty and
            // discovery ends immediately with 0 results.
            let aiozc: Any? = nil
            let trimmedHost = hostOverride.trimmingCharacters(in: .whitespacesAndNewlines)
            let hosts = trimmedHost.isEmpty ? nil : [trimmedHost]
            appendLog(hosts == nil ? "Scanning via multicast" : "Scanning host \(trimmedHost) via unicast")
            appendLog("scan args: timeout=5, hosts=\(hosts ?? [])")
            var configs: [Pyatv.Interface.BaseconfigInstance] = []
            do {
                let scanResult = try await service.scan(
                    loop: loop,
                    timeout: 5,
                    protocol_: .airPlay,
                    hosts: hosts,
                    aiozc: aiozc,
                    storage: storage
                )
                configs = scanResult ?? []
            } catch {
                lastError = "Scan failed: \(error)"
                status = "Scan failed"
                appendLog("Scan error: \(error)")
                isScanning = false
                return
            }
            appendLog("scan result type=\(type(of: configs as Any)) count=\(configs.count)")

            var filtered: [Pyatv.Interface.BaseconfigInstance] = []
            var labels: [String] = []
            for (idx, config) in configs.enumerated() {
                let info = await describeConfig(config, index: idx)
                if filterHomePodsOnly && !info.isHomePod {
                    appendLog("Filter[\(idx)] SKIP (non-HomePod): label=\(info.label) details=\(info.details)")
                    continue
                }
                appendLog("Filter[\(idx)] KEEP: label=\(info.label) details=\(info.details)")
                filtered.append(config)
                labels.append(info.label)
            }

            devices = filtered
            deviceLabels = labels
            status = filtered.isEmpty ? "No devices found" : "Found \(filtered.count) device(s)"
            appendLog("Scan finished: \(filtered.count) device(s)")
            isScanning = false
        }
    }
    
    func connect(to device: Pyatv.Interface.BaseconfigInstance, label: String) async {
        guard isReady, let service = pyatvService else {
            lastError = "Initialize runtime first."
            return
        }
        isBusy = true
        connectionStatus = "Connecting..."
        await disconnectCurrentDevice()
        let loop = await ensureAsyncioLoop()
        let storage = await ensureStorage(loop: loop)

        let labelSuffix = "AirPlay"
        connectionStatus = "Connecting (\(labelSuffix))..."
        do {
            guard let atv = try await service.connect(
                config: device,
                loop: loop,
                protocol_: .airPlay,
                session: nil,
                storage: storage
            ) else {
                connectionStatus = "Connection failed"
                lastError = "Connect returned nil (\(labelSuffix))"
                appendLog(lastError ?? "Connect returned nil")
                isBusy = false
                return
            }
            let remote = try? await atv.remote_control()
            let metadata = try? await atv.metadata()
            connectedAtv = atv
            connectedRemote = remote
            connectedMetadata = metadata
            let finalLabel = label.nonEmpty ?? "Device"
            connectedName = finalLabel
            connectionStatus = "Connected to \(finalLabel)"
            appendLog("Connect OK (\(labelSuffix)): \(finalLabel)")
            lastError = nil
            lastConnectedDevice = device
            lastConnectedLabel = finalLabel
            connectedProtocolLabel = labelSuffix
            hasRemoteControl = (connectedRemote != nil)
            lastNowPlayingSignature = ""
            startWorker()
            enqueueWorkerEvent(.refresh)
            isBusy = false
            return
        } catch {
            connectionStatus = "Connection failed"
            lastError = "Connect error (\(labelSuffix)): \(error)"
            appendLog(lastError ?? "Connect error")
        }
        connectedAtv = nil
        connectedRemote = nil
        connectedMetadata = nil
        hasRemoteControl = false
        connectedProtocolLabel = nil
        stopWorker()
        isBusy = false
    }
    
    private func appendLog(_ message: String) {
        let prefix = timeFormatter.string(from: Date())
        let line = "[\(prefix)] \(message)"
        logMessages.append(line)
        print(line) // mirror into Xcode/Console for easier debugging
        if logMessages.count > 12 {
            logMessages.removeFirst(logMessages.count - 12)
        }
    }

    private struct ConfigSummary {
        let label: String
        let details: String
        let isHomePod: Bool
    }

    private func describeConfig(_ config: Pyatv.Interface.BaseconfigInstance, index: Int) async -> ConfigSummary {
        var lines: [String] = []
        var directLabel: String?
        await appendStringifiedLines(from: config, into: &lines)
        directLabel = extractPreferredLabel(from: lines)
        if directLabel == nil, let mainService = try? await config.main_service() {
            await appendStringifiedLines(from: mainService, into: &lines)
            if directLabel == nil {
                directLabel = extractPreferredLabel(from: lines)
            }
        }
        if directLabel == nil {
            let fallbackProtocols: [Pyatv.Const.PyatvProtocol_] = [.airPlay, .rAOP]
            for proto in fallbackProtocols {
                if let service = try? await config.get_service(protocol_: proto) {
                    await appendStringifiedLines(from: service, into: &lines)
                    if directLabel == nil {
                        directLabel = extractPreferredLabel(from: lines)
                    }
                }
            }
        }
        let label = directLabel ?? labelFromLines(lines, fallbackIndex: index)
        if label.hasPrefix("Device #") {
            let sample = lines.prefix(2).joined(separator: " | ")
            appendLog("Label fallback for index \(index); lines=\(lines.count) sample=\(sample)")
        }
        let details = lines.isEmpty ? "-" : lines.prefix(3).joined(separator: " | ")
        let isHomePod = isHomePodDevice(from: lines)
        return ConfigSummary(label: label, details: details, isHomePod: isHomePod)
    }

    private func isHomePodDevice(from lines: [String]) -> Bool {
        let haystack = lines.joined(separator: " ").lowercased()
        if haystack.contains("homepod") { return true }
        if haystack.contains("audioaccessory") { return true }
        if haystack.contains("homepod mini") { return true }
        if haystack.contains("homepodmini") { return true }
        return false
    }

    private func appendStringifiedLines(from model: Any, into lines: inout [String]) async {
        if let config = model as? Pyatv.Interface.BaseconfigInstance {
            var directLines: [String] = []
            if let name = try? await config.name(), !name.isEmpty {
                directLines.append("name: \(name)")
            }
            if let identifier = try? await config.identifier(), !identifier.isEmpty {
                directLines.append("identifier: \(identifier)")
            }
            if let identifiers = try? await config.all_identifiers(), !identifiers.isEmpty {
                directLines.append("identifiers: \(identifiers.joined(separator: ", "))")
            }
            if let info = try? await config.device_info() {
                if let modelName = try? await info.model_str(), !modelName.isEmpty {
                    directLines.append("model: \(modelName)")
                }
                if let version = try? await info.version(), !version.isEmpty {
                    directLines.append("version: \(version)")
                }
            }
            if !directLines.isEmpty {
                appendTrimmedLines(directLines, into: &lines)
                return
            }
        }
        if let service = model as? Pyatv.Interface.BaseserviceInstance {
            var directLines: [String] = []
            if let proto = try? await service.`protocol`() {
                directLines.append("protocol: \(proto.rawValue)")
            }
            if let identifier = try? await service.identifier(), !identifier.isEmpty {
                directLines.append("identifier: \(identifier)")
            }
            if let port = try? await service.port() {
                directLines.append("port: \(port)")
            }
            if !directLines.isEmpty {
                appendTrimmedLines(directLines, into: &lines)
                return
            }
        }
        guard let supportService else { return }
        guard let modelLines = try? await supportService.stringify_model(model: model),
              !modelLines.isEmpty else { return }
        appendTrimmedLines(modelLines, into: &lines)
    }

    private func appendTrimmedLines(_ rawLines: [String], into lines: inout [String]) {
        for raw in rawLines {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if !lines.contains(trimmed) {
                lines.append(trimmed)
            }
        }
    }

    private func extractPreferredLabel(from lines: [String]) -> String? {
        let primaryKeys = ["gpn", "name", "hostname", "host", "address", "model", "am", "md"]
        for key in primaryKeys {
            if let value = extractValue(in: lines, key: key) {
                return value
            }
        }
        let secondaryKeys = ["identifier", "deviceid", "id"]
        for key in secondaryKeys {
            if let value = extractValue(in: lines, key: key) {
                return value
            }
        }
        return nil
    }

    private func labelFromLines(_ lines: [String], fallbackIndex: Int) -> String {
        if let preferred = extractPreferredLabel(from: lines) {
            return preferred
        }
        if let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines),
           !first.isEmpty,
           first.count < 80 {
            return first
        }
        return "Device #\(fallbackIndex + 1)"
    }

    private func extractValue(in lines: [String], key: String) -> String? {
        for line in lines {
            if let value = extractValue(from: line, key: key) {
                return value
            }
        }
        return nil
    }

    private func extractValue(from line: String, key: String) -> String? {
        let lower = line.lowercased()
        guard lower.contains(key.lowercased()) else { return nil }
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let patterns = [
            #"(?i)\b\#(escapedKey)\b\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"(?i)\b\#(escapedKey)\b\s*[:=]\s*([^,)\]}]+)"#,
            #"(?i)['"]\#(escapedKey)['"]\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"(?i)['"]\#(escapedKey)['"]\s*[:=]\s*([^,)\]}]+)"#
        ]
        for pattern in patterns {
            if let match = regexFirstMatch(pattern: pattern, in: line) {
                if let cleaned = cleanLabelCandidate(match) {
                    return cleaned
                }
            }
        }
        if let value = splitValue(line) {
            if let cleaned = cleanLabelCandidate(value) {
                return cleaned
            }
        }
        return nil
    }

    private func regexFirstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    private func cleanLabelCandidate(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if let parenIndex = value.firstIndex(of: "(") {
            let trimmed = value[..<parenIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                value = trimmed
            }
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'[]{}"))
        let lowered = value.lowercased()
        if lowered == "none" || lowered == "null" || lowered.isEmpty {
            return nil
        }
        return value
    }

    private func splitValue(_ line: String) -> String? {
        let separators: [Character] = [":", "="]
        for sep in separators {
            if let idx = line.firstIndex(of: sep) {
                let value = line[line.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }


    func labelForIndex(_ index: Int) -> String {
        if index >= 0, index < deviceLabels.count {
            return deviceLabels[index]
        }
        return "Device #\(index + 1)"
    }

    // MARK: - Remote control helpers
    private func disconnectCurrentDevice() async {
        stopWorker()
        if let atv = connectedAtv {
            try? await atv.close()
        }
        connectedAtv = nil
        connectedRemote = nil
        connectedMetadata = nil
        hasRemoteControl = false
        connectedProtocolLabel = nil
    }

    private func reconnectAfterTransportError() async {
        guard !isReconnectingAfterError else { return }
        isReconnectingAfterError = true
        defer { isReconnectingAfterError = false }
        await executor.installPythonLogForwarders(logLevel: .debug)
        await bootstrap(force: true)
        await reconnectLastDevice()
    }
    
    private func reconnectLastDevice() async {
        guard !isBusy, let device = lastConnectedDevice else { return }
        await connect(to: device, label: lastConnectedLabel ?? "Device")
    }
    
    func playPause() { remoteCommandSubject.send(.playPause) }
    func next() { remoteCommandSubject.send(.next) }
    func previous() { remoteCommandSubject.send(.previous) }
    func refreshNowPlaying() {
        guard lastConnectedDevice != nil else { return }
        if workerTask == nil || (workerTask?.isCancelled ?? false) {
            startWorker()
        }
        enqueueWorkerEvent(.refresh)
    }
    
    private func setupRemotePipeline() {
        remoteCommandSubject
            .throttle(for: .milliseconds(400), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] action in
                self?.enqueueWorkerEvent(.remote(action))
            }
            .store(in: &cancellables)
    }

    private func performRemoteAction(_ action: RemoteAction) async {
        guard let remote = connectedRemote, hasRemoteControl else {
            appendLog("Remote control unavailable")
            return
        }
        do {
            switch action {
            case .playPause:
                try await remote.play_pause()
            case .next:
                try await remote.next()
            case .previous:
                try await remote.previous()
            }
        } catch {
            appendLog("Remote command \(action) failed: \(error)")
            if "\(error)".contains("Connection") || "\(error)".contains("transport") {
                await reconnectAfterTransportError()
            }
        }
    }

    private func ensureNowPlayingMetadata() async -> Pyatv.Interface.MetadataInstance? {
        if let metadata = connectedMetadata {
            return metadata
        }
        guard let atv = connectedAtv else {
            return nil
        }
        let metadata = try? await atv.metadata()
        connectedMetadata = metadata
        return metadata
    }

    private struct NowPlayingSnapshot {
        let title: String
        let artist: String
        let album: String
        let position: Double
        let totalTime: Double
        let state: String
    }

    private func fetchNowPlayingSnapshot(
        metadata: Pyatv.Interface.MetadataInstance
    ) async -> NowPlayingSnapshot? {
        do {
            guard let playing = try await metadata.playing() else {
                return nil
            }
            let state = (try? await playing.device_state())?.rawValue.lowercased() ?? ""
            if state == "idle" {
                return nil
            }
            let title = (try? await playing.title()) ?? ""
            let artist = (try? await playing.artist()) ?? ""
            let album = (try? await playing.album()) ?? ""
            var totalTime = Double((try? await playing.total_time()) ?? 0)
            var position = Double((try? await playing.position()) ?? 0)
            if totalTime == 0 || position == 0 {
                if let ref = await playing.objectRef() {
                    if totalTime == 0, let rawTotal = try? await ref.total_time.double() {
                        totalTime = rawTotal
                    }
                    if position == 0, let rawPosition = try? await ref.position.double() {
                        position = rawPosition
                    }
                }
            }
            return NowPlayingSnapshot(
                title: title,
                artist: artist,
                album: album,
                position: position,
                totalTime: totalTime,
                state: state
            )
        } catch {
            appendLog("NowPlaying fetch failed: \(error)")
            return nil
        }
    }

    private func fetchNowPlayingSnapshotViaFreshConnection(
        logFailure: Bool
    ) async -> NowPlayingSnapshot? {
        guard let service = pyatvService, let device = lastConnectedDevice else {
            return nil
        }
        let loop = await ensureAsyncioLoop()
        let storage = await ensureStorage(loop: loop)
        do {
            guard let atv = try await service.connect(
                config: device,
                loop: loop,
                protocol_: .airPlay,
                session: nil,
                storage: storage
            ) else {
                if logFailure {
                    appendLog("NowPlaying: fresh AirPlay connect returned nil")
                }
                return nil
            }
            defer { Task { try? await atv.close() } }
            guard let metadata = try await atv.metadata() else {
                if logFailure {
                    appendLog("NowPlaying: fresh AirPlay metadata unavailable")
                }
                return nil
            }
            return await fetchNowPlayingSnapshot(metadata: metadata)
        } catch {
            if logFailure {
                appendLog("NowPlaying: fresh AirPlay fetch failed: \(error)")
            }
            return nil
        }
    }

    private func loadNowPlaying() async {
        nowPlayingPollCount += 1
        if nowPlayingPollCount % 2 == 0 {
            appendLog("NowPlaying poll #\(nowPlayingPollCount)")
        }
        guard pyatvService != nil else {
            let log = nowPlayingPollCount % 2 == 0 ? "NowPlaying: pyatv service unavailable" : nil
            resetNowPlaying(log: log)
            return
        }
        guard lastConnectedDevice != nil else {
            let log = nowPlayingPollCount % 2 == 0 ? "NowPlaying: no connected device" : nil
            resetNowPlaying(log: log)
            return
        }
        let shouldLog = nowPlayingPollCount % 2 == 0
        let snapshot: NowPlayingSnapshot?
        if useFreshNowPlayingConnection, connectedProtocolLabel == "AirPlay" {
            snapshot = await fetchNowPlayingSnapshotViaFreshConnection(logFailure: shouldLog)
        } else {
            guard let metadata = await ensureNowPlayingMetadata() else {
                let log = shouldLog ? "NowPlaying: metadata unavailable" : nil
                resetNowPlaying(log: log)
                return
            }
            snapshot = await fetchNowPlayingSnapshot(metadata: metadata)
        }
        guard let snapshot else {
            let log = nowPlayingPollCount % 2 == 0 ? "NowPlaying: playing info unavailable" : nil
            resetNowPlaying(log: log)
            return
        }
        if snapshot.state == "paused" {
            let log = nowPlayingPollCount % 2 == 0 ? "NowPlaying: no playback (paused)" : nil
            resetNowPlaying(log: log)
            return
        }
        applyNowPlayingValues(
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            position: snapshot.position,
            totalTime: snapshot.totalTime,
            logUnchanged: nowPlayingPollCount % 2 == 0,
            logTimingUnavailable: nowPlayingPollCount % 4 == 0
        )
    }

    private func resetNowPlaying(log: String?) {
        nowPlayingTitle = ""
        nowPlayingSubtitle = ""
        nowPlayingPosition = 0
        nowPlayingDuration = 0
        if !lastNowPlayingSignature.isEmpty {
            lastNowPlayingSignature = ""
        }
        if let log {
            appendLog(log)
        }
    }

    private func applyNowPlayingValues(
        title: String,
        artist: String,
        album: String,
        position: Double,
        totalTime: Double,
        logUnchanged: Bool,
        logTimingUnavailable: Bool
    ) {
        nowPlayingTitle = title
        let subtitleParts = [artist, album].filter { !$0.isEmpty }
        nowPlayingSubtitle = subtitleParts.joined(separator: " • ")
        nowPlayingPosition = position
        nowPlayingDuration = totalTime
        let positionInt = Int(position.rounded(.down))
        let totalTimeInt = Int(totalTime.rounded(.down))
        if logTimingUnavailable, totalTimeInt == 0, positionInt == 0, !title.isEmpty {
            let proto = connectedProtocolLabel ?? "-"
            appendLog("NowPlaying timing unavailable (protocol \(proto))")
        }
        let signature = makeNowPlayingSignature(
            title: title,
            artist: artist,
            album: album,
            position: positionInt,
            totalTime: totalTimeInt
        )
        if signature != lastNowPlayingSignature {
            lastNowPlayingSignature = signature
            appendLog("NowPlaying updated: \(title) | \(artist) | \(album) \(positionInt)/\(totalTimeInt)")
        } else if logUnchanged {
            appendLog("NowPlaying polled (unchanged): \(title) | \(artist) | \(album) \(positionInt)/\(totalTimeInt)")
        }
    }

    private func makeNowPlayingSignature(
        title: String,
        artist: String,
        album: String,
        position: Int,
        totalTime: Int
    ) -> String {
        "\(title)|\(artist)|\(album)|\(position)/\(totalTime)"
    }

    private func startWorker() {
        stopWorker()
        let stream = AsyncStream<WorkerEvent> { continuation in
            workerContinuation = continuation
        }
        workerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for await event in stream {
                switch event {
                case .poll:
                    pollEnqueued = false
                    await loadNowPlaying()
                case .refresh:
                    pollEnqueued = false
                    await loadNowPlaying()
                case .remote(let action):
                    await performRemoteAction(action)
                }
            }
        }
        pollTimerTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    self.enqueueWorkerEvent(.poll)
                }
            }
        }
    }

    private func stopWorker() {
        pollTimerTask?.cancel()
        pollTimerTask = nil
        workerContinuation?.finish()
        workerContinuation = nil
        workerTask?.cancel()
        workerTask = nil
        pollEnqueued = false
    }

    private func enqueueWorkerEvent(_ event: WorkerEvent) {
        switch event {
        case .poll:
            guard !pollEnqueued else { return }
            pollEnqueued = true
        default:
            break
        }
        workerContinuation?.yield(event)
    }

    func resumeNowPlayingUpdates() {
        guard lastConnectedDevice != nil else { return }
        if workerTask == nil || (workerTask?.isCancelled ?? false) {
            startWorker()
        }
    }

    private func ensureAsyncioLoop() async -> AsyncioLoop {
        if let loop = asyncioLoop {
            return loop
        }
        let loop = await executor.createAsyncioLoop()
        asyncioLoop = loop
        return loop
    }

    private func ensureStorage(loop: AsyncioLoop) async -> Pyatv.Interface.StorageInstance? {
        if let storageInstance {
            return storageInstance
        }
        if let storagePath = defaultStoragePath(),
           let fileStorage = try? await Pyatv.Storage.FileStorage.FilestorageInstance.create(
                executor: executor,
                filename: storagePath,
                loop: loop
           ) {
            self.fileStorage = fileStorage
            try? await fileStorage.load()
            if let storageRef = await fileStorage.objectRef() {
                storageInstance = await Pyatv.Interface.StorageInstance.attach(executor: executor, ref: storageRef)
            }
            appendLog("Storage ready: \(storagePath)")
            return storageInstance
        }

        if let memoryStorage = try? await Pyatv.Storage.MemoryStorage.MemorystorageInstance.create(executor: executor) {
            self.memoryStorage = memoryStorage
            if let storageRef = await memoryStorage.objectRef() {
                storageInstance = await Pyatv.Interface.StorageInstance.attach(executor: executor, ref: storageRef)
            }
            appendLog("Storage ready: MemoryStorage")
            return storageInstance
        }

        appendLog("Storage init failed")
        return nil
    }

    private func defaultStoragePath() -> String? {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent(".pyatv.conf").path
    }
}

struct ContentView: View {
    @StateObject private var viewModel: PyatvViewModel
    @State private var navigateToRemote: Bool = false
    
    init(executor: PythonExecutor) {
        _viewModel = StateObject(wrappedValue: PyatvViewModel(executor: executor))
    }
    
    var body: some View {
        TabView {
            discoverTab
                .tabItem {
                    Label("Discover", systemImage: "dot.radiowaves.left.and.right")
                }
            logTab
                .tabItem {
                    Label("Logs", systemImage: "list.bullet.rectangle")
                }
        }
        .task {
            await viewModel.bootstrap()
        }
    }
    
    private var discoverTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    runtimeCard
                    actionButtons
                    DeviceListView(
                        devices: viewModel.devices,
                        isBusy: viewModel.isBusy,
                        isScanning: viewModel.isScanning,
                        labelForDevice: { _, idx in
                            viewModel.labelForIndex(idx)
                        },
                        onConnect: { entry, idx in
                            let label = viewModel.labelForIndex(idx)
                            Task {
                                await viewModel.connect(to: entry, label: label)
                                await MainActor.run {
                                    if viewModel.hasRemoteControl {
                                        navigateToRemote = true
                                    }
                                }
                            }
                        }
                    )
                    NavigationLink("", isActive: $navigateToRemote) {
                        RemoteView(viewModel: viewModel) {
                            viewModel.refreshNowPlaying()
                        }
                    }
                    .hidden()
                }
                .padding()
            }
            
            .navigationTitle("HomePod Remote")
        }
    }
    
    private var runtimeCard: some View {
        GroupBox("Runtime") {
            HStack {
                Text("Status")
                Spacer()
                Text(viewModel.status)
                    .foregroundStyle(.secondary)
            }
            
            if let error = viewModel.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.top, 4)
            }
        }
    }
    
    private var actionButtons: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                viewModel.scan()
            } label: {
                Label("Scan", systemImage: "dot.radiowaves.left.and.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.isReady || viewModel.isBusy || viewModel.isScanning)
            
            TextField("Optional host/IP for unicast scan (e.g. 192.168.1.50)", text: $viewModel.hostOverride)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .textFieldStyle(.roundedBorder)
        }
    }
    
    
    private var logTab: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    GroupBox("Connection") {
                        Text("Current: \(viewModel.connectionStatus)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    GroupBox("Log") {
                        if viewModel.logMessages.isEmpty {
                            Text("Actions will be logged here.")
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(viewModel.logMessages.enumerated()), id: \.offset) { _, entry in
                                    Text(entry)
                                        .font(.caption)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Diagnostics")
        }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview {
    ContentView(executor: PythonExecutor())
}
