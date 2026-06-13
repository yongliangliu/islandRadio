import SwiftUI
import UniformTypeIdentifiers

/// Main window content — station list with playback controls
struct MainContentView: View {
    @EnvironmentObject var stationStore: StationStore
    @EnvironmentObject var audioPlayer: AudioPlayer
    @EnvironmentObject var sttBridge: STTBridgeServer
    @EnvironmentObject var wordStore: WordStore

    @State private var showAddSheet = false
    @State private var showSettingsSheet = false
    @State private var editingStation: RadioStation?
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar

            Divider()

            // Content
            if selectedTab == 0 {
                if stationStore.stations.isEmpty {
                    emptyState
                } else {
                    stationList
                }
            } else {
                wordListView
            }

            Divider()

            // Player bar
            playerBar
        }
        .frame(minWidth: 380, minHeight: 460)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showAddSheet) {
            AddStationView()
                .environmentObject(stationStore)
        }
        .sheet(isPresented: $showSettingsSheet) {
            LLMSettingsView()
        }
        .sheet(item: $editingStation) { station in
            EditStationView(station: station)
                .environmentObject(stationStore)
        }
        .onAppear {
            audioPlayer.checkReachability(for: stationStore.stations)
        }
        .onChange(of: stationStore.stations.count) { _ in
            audioPlayer.checkReachability(for: stationStore.stations)
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            // STT connection indicator
            HStack(spacing: 5) {
                Circle()
                    .fill(sttBridge.isListening ? Color.green : (sttBridge.isConnected ? Color.blue : Color.gray))
                    .frame(width: 8, height: 8)
                Text(sttBridge.isListening ? "识别中" : (sttBridge.isConnected ? "STT 就绪" : "STT"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // View toggle: segmented style with larger icons
            HStack(spacing: 2) {
                Button(action: { selectedTab = 0 }) {
                    Image(systemName: "radio")
                        .font(.system(size: 13, weight: selectedTab == 0 ? .semibold : .regular))
                        .foregroundStyle(selectedTab == 0 ? .primary : .secondary)
                        .frame(width: 28, height: 28)
                        .background(selectedTab == 0 ? Color.accentColor.opacity(0.12) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.borderless)
                .help("电台列表")

                Button(action: { selectedTab = 1 }) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 13, weight: selectedTab == 1 ? .semibold : .regular))
                        .foregroundStyle(selectedTab == 1 ? .primary : .secondary)
                        .frame(width: 28, height: 28)
                        .background(selectedTab == 1 ? Color.accentColor.opacity(0.12) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.borderless)
                .help("生词本")
            }

            Button(action: { showSettingsSheet = true }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("LLM 设置")

            Button(action: { showAddSheet = true }) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .help("添加电台")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Station list

    private var stationList: some View {
        List {
            ForEach(stationStore.stations) { station in
                StationRow(
                    station: station,
                    isPlaying: audioPlayer.isPlaying && audioPlayer.currentStation == station,
                    isReachable: audioPlayer.reachability[station.id] ?? nil,
                    onPlay: { audioPlayer.toggle(station: station) },
                    onEdit: { editingStation = station },
                    onDelete: {
                        if audioPlayer.currentStation == station {
                            audioPlayer.stop()
                        }
                        if let idx = stationStore.stations.firstIndex(where: { $0.id == station.id }) {
                            stationStore.remove(at: IndexSet(integer: idx))
                        }
                    }
                )
            }
            .onDelete { offsets in
                // Stop if deleting current station
                if let current = audioPlayer.currentStation,
                   offsets.contains(where: { stationStore.stations[$0].id == current.id }) {
                    audioPlayer.stop()
                }
                stationStore.remove(at: offsets)
            }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "radio")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("暂无电台")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("点击右上角 + 添加电台")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }

    // MARK: - Word list

    private var wordListView: some View {
        Group {
            if wordStore.items.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("暂无生词")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("播放电台时点击字幕中的单词即可查询并收录")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    // Toolbar with export button
                    HStack {
                        Spacer()
                        Button(action: exportFlashcardPDF) {
                            Label("导出 PDF", systemImage: "square.and.arrow.up")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    Divider()
                    List {
                        ForEach(wordStore.items) { item in
                            WordRow(item: item, onDelete: {
                                wordStore.remove(id: item.id)
                            })
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { wordStore.items[$0].id }
                            ids.forEach { wordStore.remove(id: $0) }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
    }

    /// Export word list as PDF flashcards (A4, 3 columns × 4 rows per page)
    private func exportFlashcardPDF() {
        let items = wordStore.items.filter { !$0.mastered }
        guard !items.isEmpty else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "IslandRadio_Flashcards.pdf"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let pdf = FlashcardPDFGenerator.generate(items: items)
        try? pdf.write(to: url)
        NSWorkspace.shared.open(url)
    }

    // MARK: - Player bar

    private var playerBar: some View {
        HStack(spacing: 12) {
            // Current station info
            if let station = audioPlayer.currentStation {
                Circle()
                    .fill((audioPlayer.reachability[station.id] ?? nil) ?? true ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(audioPlayer.isPlaying ? 1 : 0.4)

                Text(station.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Text("未选择电台")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Mic button (STT toggle)
            Button(action: toggleRecording) {
                Image(systemName: sttBridge.isListening ? "mic.fill" : "mic")
                    .foregroundStyle(sttBridge.isListening ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .help("语音识别（将在浏览器中打开）")

            // Play/Pause
            Button(action: {
                if let station = audioPlayer.currentStation {
                    audioPlayer.toggle(station: station)
                }
            }) {
                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
            }
            .buttonStyle(.borderless)
            .disabled(audioPlayer.currentStation == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func toggleRecording() {
        appLog("[UI] toggleRecording: isListening=\(sttBridge.isListening), connected=\(sttBridge.isConnected)")
        if sttBridge.isListening {
            sttBridge.stopSTT()
        } else {
            let lang = audioPlayer.currentStation?.language ?? "en-US"
            appLog("[UI] starting STT with lang=\(lang)")
            sttBridge.startSTT(lang: lang)
        }
    }
}

// MARK: - Station Row

struct StationRow: View {
    let station: RadioStation
    let isPlaying: Bool
    let isReachable: Bool?  // nil = checking, true = reachable, false = unreachable
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Connection status indicator
            Circle()
                .fill(reachabilityColor)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                )
                .help(reachabilityTooltip)

            VStack(alignment: .leading, spacing: 2) {
                Text(station.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(station.language)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isPlaying {
                // Playing indicator (3 bars animation via SF Symbol)
                Image(systemName: "waveform")
                    .foregroundStyle(.blue)
                    .symbolEffect(.variableColor.iterative, isActive: true)
            }

            if isHovered {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("编辑电台")
            }

            Button(action: onPlay) {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("编辑", action: onEdit)
            Divider()
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    private var reachabilityColor: Color {
        if let reachable = isReachable {
            return reachable ? .green : .red
        }
        return .gray  // checking
    }

    private var reachabilityTooltip: String {
        if let reachable = isReachable {
            return reachable ? "可连接" : "无法连接"
        }
        return "检测中..."
    }
}

// MARK: - Word Row

struct WordRow: View {
    let item: LearningItem
    let onDelete: () -> Void
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header: word + phonetic + syllableBreakdown + timestamp
            HStack(alignment: .firstTextBaseline) {
                Text(item.word)
                    .font(.system(size: 14, weight: .bold))

                if let phonetic = item.phonetic, !phonetic.isEmpty {
                    Text(phonetic)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let syllable = item.syllableBreakdown, !syllable.isEmpty {
                    Text("· \(syllable)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(item.timestamp, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Meaning
            if let meaning = item.meaning, !meaning.isEmpty {
                Text(meaning)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.orange)
            }

            // Example sentence — always visible
            if let example = item.example, !example.isEmpty {
                Text(example)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // Expanded details
            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    if let root = item.rootAnalysis, !root.isEmpty {
                        Label(root, systemImage: "tree")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let sentence = item.sentenceTranslation, !sentence.isEmpty {
                        Label(sentence, systemImage: "bubble.left")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("来源: \(item.stationName)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("删除单词")
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
    }
}

// MARK: - Add Station Sheet

struct AddStationView: View {
    @EnvironmentObject var stationStore: StationStore
    @Environment(\.dismiss) var dismiss

    @State private var name = ""
    @State private var url = ""
    @State private var language = "en-US"

    private let maxNameLength = 20

    var body: some View {
        VStack(spacing: 12) {
            Text("添加电台")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("名称")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    TextField("电台名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { newValue in
                            if newValue.count > maxNameLength {
                                name = String(newValue.prefix(maxNameLength))
                            }
                        }
                    Text("\(name.count)/\(maxNameLength)")
                        .font(.system(size: 10))
                        .foregroundStyle(name.count >= maxNameLength ? Color.red : Color.gray.opacity(0.5))
                        .frame(width: 30)
                }

                HStack(spacing: 6) {
                    Text("URL")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    TextField("http://... .aac / .m3u8", text: $url)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 6) {
                    Text("语言")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    Picker("", selection: $language) {
                        ForEach(RadioStation.supportedLanguages, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                    .labelsHidden()
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("添加") {
                    let station = RadioStation(
                        id: UUID().uuidString,
                        name: String(name.prefix(maxNameLength)),
                        url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                        language: language,
                        color: nil
                    )
                    stationStore.add(station)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || url.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

// MARK: - Edit Station Sheet

struct EditStationView: View {
    @EnvironmentObject var stationStore: StationStore
    @Environment(\.dismiss) var dismiss

    let station: RadioStation

    @State private var name: String
    @State private var url: String
    @State private var language: String

    private let maxNameLength = 20

    init(station: RadioStation) {
        self.station = station
        _name = State(initialValue: station.name)
        _url = State(initialValue: station.url)
        _language = State(initialValue: station.language)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("编辑电台")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("名称")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    TextField("电台名称", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: name) { newValue in
                            if newValue.count > maxNameLength {
                                name = String(newValue.prefix(maxNameLength))
                            }
                        }
                    Text("\(name.count)/\(maxNameLength)")
                        .font(.system(size: 10))
                        .foregroundStyle(name.count >= maxNameLength ? Color.red : Color.gray.opacity(0.5))
                        .frame(width: 30)
                }

                HStack(spacing: 6) {
                    Text("URL")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    TextField("http://... .aac / .m3u8", text: $url)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 6) {
                    Text("语言")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                    Picker("", selection: $language) {
                        ForEach(RadioStation.supportedLanguages, id: \.code) { lang in
                            Text(lang.label).tag(lang.code)
                        }
                    }
                    .labelsHidden()
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    var updated = station
                    updated.name = String(name.prefix(maxNameLength))
                    updated.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.language = language
                    stationStore.update(updated)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || url.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}

// MARK: - LLM Settings

struct LLMSettingsView: View {
    @Environment(\.dismiss) var dismiss

    @State private var config = LLMConfig.load()
    @State private var testStatus = ""
    @State private var isTesting = false

    var body: some View {
        VStack(spacing: 16) {
            Text("LLM 设置")
                .font(.headline)

            Form {
                Picker("服务商", selection: $config.provider) {
                    Text("OpenAI").tag(LLMProvider.openai)
                    Text("Anthropic").tag(LLMProvider.anthropic)
                }
                .onChange(of: config.provider) { newProvider in
                    // Fill preset endpoint/model when switching provider
                    if let preset = LLMConfig.presets[newProvider] {
                        config.endpoint = preset.endpoint
                        config.model = preset.model
                    }
                }

                TextField("API Endpoint", text: $config.endpoint)
                    .textFieldStyle(.roundedBorder)

                SecureField("API Key", text: $config.apiKey)
                    .textFieldStyle(.roundedBorder)

                TextField("模型", text: $config.model)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)

            // Test status
            if !testStatus.isEmpty {
                Text(testStatus)
                    .font(.caption)
                    .foregroundStyle(testStatus.contains("成功") ? .green : .red)
                    .lineLimit(2)
            }

            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("测试连接") {
                    testConnection()
                }
                .disabled(config.apiKey.isEmpty || isTesting)

                Button("保存") {
                    config.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(config.apiKey.isEmpty)
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 400)
    }

    private func testConnection() {
        isTesting = true
        testStatus = "测试中..."

        Task {
            do {
                let result = try await LLMService.translateWord("hello", sentence: "Hello world", config: config)
                testStatus = "连接成功: \(result.meaning ?? "OK")"
            } catch {
                testStatus = "失败: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }
}

// MARK: - Color hex extension for SwiftUI

extension Color {
    init?(hex: String) {
        var hexStr = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexStr.hasPrefix("#") { hexStr.removeFirst() }
        guard hexStr.count == 6, let rgb = UInt64(hexStr, radix: 16) else { return nil }
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
