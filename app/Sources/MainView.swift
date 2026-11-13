import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var engine: Engine
    @AppStorage("showInspector") private var showInspector = true
    @State private var showBrowser = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TopBar(engine: engine, showInspector: $showInspector, showBrowser: $showBrowser)
                ZStack(alignment: .bottom) {
                    if showBrowser {
                        ModelBrowser(engine: engine, isPresented: $showBrowser)
                            .transition(.softAppear)
                    } else {
                        TopologyCanvas(engine: engine)
                            .transition(.opacity)
                    }
                    if let problem = engine.problem {
                        ProblemToast(text: problem) { engine.problem = nil }
                            .padding(.bottom, 18)
                            .transition(.softAppear)
                    }
                }
                .animation(Chrome.panelSlide, value: showBrowser)
                .animation(Chrome.panelSlide, value: engine.problem)
            }
            if showInspector {
                Inspector(engine: engine)
                    .frame(width: 300)
                    .background(Chrome.overlay(0.035))
                    .overlay(alignment: .leading) { Rectangle().fill(Chrome.overlay(0.08)).frame(width: 1) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Chrome.panelSlide, value: showInspector)
        .frame(minWidth: 860, minHeight: 560)
    }
}

// MARK: - Top bar

struct TopBar: View {
    @ObservedObject var engine: Engine
    @Binding var showInspector: Bool
    @Binding var showBrowser: Bool

    var body: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 96)  // traffic lights
            HStack(spacing: 0) {
                ModelMenu(engine: engine, showBrowser: $showBrowser)
                Rectangle().fill(Chrome.overlay(0.12)).frame(width: 1, height: 16)
                EndpointLabel(engine: engine)
            }
            .chromeGlassCapsule()
            Spacer(minLength: 10)
            PlayButton(engine: engine)
            ChromeCircleButton(symbol: "sidebar.right", help: showInspector ? "Hide details" : "Show details") {
                showInspector.toggle()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: WindowChrome.titlebarHeight + 6)
    }
}

struct ModelMenu: View {
    @ObservedObject var engine: Engine
    @Binding var showBrowser: Bool
    @State private var isPresented = false
    @State private var isHovering = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "cube").font(Chrome.inlineIconFont).foregroundStyle(Chrome.secondaryText)
                Text(verbatim: engine.selectedRepo.map(Fmt.modelName) ?? "Choose a model")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 240, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(isHovering || isPresented ? 1 : 0.92))
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            PopoverMenu {
                if !engine.local.isEmpty {
                    PopoverSectionHeader("On this Mac")
                    ForEach(engine.local) { model in
                        LocalModelItem(model: model, isChecked: model.repo == engine.selectedRepo,
                                       needsCluster: model.fit == "too_big"
                                           && engine.fitsCluster(model.sizeBytes, splittable: model.splittable)) {
                            engine.select(model.repo)
                        }
                    }
                    Divider().padding(.vertical, 4)
                }
                PopoverItem("Get models…") { showBrowser = true }
            }
        }
    }
}

struct LocalModelItem: View {
    let model: LocalModel
    let isChecked: Bool
    var needsCluster = false
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isHovering = false

    var body: some View {
        Button {
            dismiss()
            action()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                    .opacity(isChecked ? 1 : 0).frame(width: 14)
                Text(verbatim: Fmt.modelName(model.repo)).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 16)
                Text(verbatim: needsCluster ? "Split · \(Fmt.size(model.sizeBytes))"
                     : model.fit == "too_big" ? "Too big" : Fmt.size(model.sizeBytes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(unusable ? Chrome.danger : Chrome.secondaryText)
            }
            .foregroundStyle(Chrome.primaryText.opacity(unusable ? 0.5 : 1))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isHovering ? Chrome.overlay(0.1) : .clear))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(unusable)
        .onHover { h in withAnimation(Chrome.hover) { isHovering = h } }
    }

    private var unusable: Bool { model.fit == "too_big" && !needsCluster }
}

struct EndpointLabel: View {
    @ObservedObject var engine: Engine
    @State private var copied = false

    var body: some View {
        let endpoint = engine.status?.server.endpoint ?? "http://localhost:\(engine.port)/v1"
        let serving = engine.status?.runtime.state == "ready"
        Button {
            Clipboard.copy(endpoint)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
        } label: {
            HStack(spacing: 7) {
                Text(verbatim: endpoint)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(serving ? Chrome.primaryText : Chrome.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(copied ? Chrome.success : Chrome.secondaryText)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.horizontal, Chrome.capsuleHorizontalPadding)
            .frame(height: Chrome.capsuleHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Copy the API address")
    }
}

struct PlayButton: View {
    @ObservedObject var engine: Engine

    var body: some View {
        let state = engine.status?.runtime.state ?? "idle"
        let selected = engine.local.first { $0.repo == engine.selectedRepo }
        if engine.status?.split?.role == "member" {
            ChromeCircleButton(symbol: "play.fill", help: "This Mac is running part of another Mac's model") {}
                .disabled(true).opacity(0.45)
        } else if state == "loading" {
            ProgressView().controlSize(.small)
                .frame(width: Chrome.capsuleHeight, height: Chrome.capsuleHeight)
                .chromeGlassCircle()
                .help("Loading the model")
        } else if state == "ready" {
            ChromeCircleButton(symbol: "stop.fill", help: "Stop serving") { engine.stop() }
        } else {
            ChromeCircleButton(symbol: "play.fill", help: engine.selectedRepo == nil ? "Get a model first" : "Load the model and serve it") {
                // Too big for this Mac alone but fits the cluster: split it.
                if let selected, selected.fit == "too_big" { engine.startSplit() } else { engine.start() }
            }
            .disabled(engine.selectedRepo == nil || !engine.connected)
            .opacity(engine.selectedRepo == nil ? 0.45 : 1)
        }
    }
}

struct ProblemToast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Chrome.warning)
            Text(verbatim: text).font(.system(size: 12.5)).lineLimit(2)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Chrome.secondaryText)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: Capsule(style: .continuous))
        .frame(maxWidth: 520)
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Inspector

struct Inspector: View {
    @ObservedObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
                if let s = engine.status {
                    server(s)
                    model(s)
                    hardware(s)
                    cluster(s)
                } else {
                    ChromeSection(title: "Server") {
                        ChromeCard {
                            ChromeRow(title: engine.problem == nil ? "Starting the engine…" : "Engine not running") {
                                if engine.problem == nil { ProgressView().controlSize(.small) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Chrome.contentHorizontalPadding)
            .padding(.top, WindowChrome.titlebarHeight + 10)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.never)
    }

    private func server(_ s: Status) -> some View {
        let rt = s.runtime
        return ChromeSection(title: "Server") {
            ChromeCard {
                InfoRow("Status", statusText(rt), tint: rt.state == "error" ? Chrome.danger : nil)
                ChromeRowDivider()
                InfoRow("Mode", modeText(s))
                ChromeRowDivider()
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    InfoRow("Uptime", rt.loadedAt.map { Fmt.duration(ctx.date.timeIntervalSince1970 - $0) } ?? "—")
                }
                ChromeRowDivider()
                InfoRow("Endpoint", s.server.endpoint.replacingOccurrences(of: "http://", with: ""), mono: true)
                if rt.state == "ready" && s.split == nil {
                    ChromeRowDivider()
                    InfoRow("Requests", rt.active + rt.queued > 0 ? "\(rt.active) running · \(rt.queued) waiting" : "\(rt.served) served")
                }
            }
            HStack {
                ChromeTextButton(symbol: "doc.on.doc", title: "Copy API", help: "Copy the API address") {
                    Clipboard.copy(s.server.endpoint)
                }
                ChromeTextButton(symbol: "terminal", title: "Copy curl", help: "Copy a test request") {
                    Clipboard.copy(curl(s))
                }
                .disabled(rt.state != "ready")
            }
        }
    }

    private func statusText(_ rt: RuntimeInfo) -> String {
        if let split = engine.status?.split, split.role == "member" {
            switch split.state {
            case "ready": return "Running part of a split model"
            case "error": return split.error ?? "Failed"
            default: return "Loading its share…"
            }
        }
        switch rt.state {
        case "ready": return "Running"
        case "loading": return "Loading…"
        case "error": return rt.error ?? "Failed"
        default: return "Stopped"
        }
    }

    private func modeText(_ s: Status) -> String {
        guard let split = s.split else { return "Standalone" }
        let macs = split.split.count
        return split.role == "coordinator" ? "Split across \(macs)" : "Member · rank \(split.rank)"
    }

    private func curl(_ s: Status) -> String {
        """
        curl \(s.server.endpoint)/chat/completions -H 'Content-Type: application/json' \
        -d '{"model":"\(s.runtime.repo ?? "")","messages":[{"role":"user","content":"Hello"}]}'
        """
    }

    private func model(_ s: Status) -> some View {
        let rt = s.runtime
        return ChromeSection(title: "Model") {
            ChromeCard {
                InfoRow("Loaded", rt.repo.map(Fmt.modelName) ?? "—")
                if let split = s.split, let layers = split.layers {
                    ChromeRowDivider()
                    InfoRow("This Mac runs", "Layers \(layers[0])–\(layers[1]) of \(split.split.reduce(0, +))")
                } else {
                    ChromeRowDivider()
                    InfoRow("Weights", rt.weightsBytes > 0 ? Fmt.size(rt.weightsBytes) : "—")
                    ChromeRowDivider()
                    InfoRow("Generation", rt.lastTps.map { String(format: "%.1f tok/s", $0) } ?? "—")
                    ChromeRowDivider()
                    InfoRow("Prompt", rt.lastPromptTps.map { String(format: "%.0f tok/s", $0) } ?? "—")
                    ChromeRowDivider()
                    InfoRow("Tokens out", Fmt.count(rt.tokensOut))
                }
            }
        }
    }

    private func hardware(_ s: Status) -> some View {
        let hw = s.hardware
        return ChromeSection(title: "Hardware") {
            ChromeCard {
                InfoRow("Chip", s.node.chip)
                ChromeRowDivider()
                InfoRow("GPU", s.node.gpuCores.map { "\($0) cores" } ?? "—")
                ChromeRowDivider()
                InfoRow("Model memory", Fmt.size(s.node.gpuBudgetBytes))
                ChromeRowDivider()
                InfoRow("Thunderbolt", hw.thunderboltPorts == 0 ? "None"
                        : "\(hw.thunderboltPorts) ports · \(hw.thunderboltGeneration.map { $0 >= 5 ? "TB5" : "TB4 / USB4" } ?? "—")")
                ChromeRowDivider()
                InfoRow("RDMA", rdmaText(hw))
            }
        }
    }

    private func rdmaText(_ hw: HardwareInfo) -> String {
        if hw.rdma == "enabled" { return "On" }
        if (hw.thunderboltGeneration ?? 0) < 5 { return "Needs Thunderbolt 5" }
        return hw.rdma == "unavailable" ? "Needs macOS 26.2" : "Off · rdma_ctl enable in Recovery"
    }

    private func cluster(_ s: Status) -> some View {
        let c = s.cluster
        let used = c.memoryBytes > 0 ? Double(c.memoryUsedBytes) / Double(c.memoryBytes) : 0
        return ChromeSection(title: "Cluster") {
            ChromeCard {
                InfoRow("Macs", "\(c.machines)")
                ChromeRowDivider()
                InfoRow("Pooled memory", Fmt.memory(c.memoryBytes))
                ChromeRowDivider()
                InfoRow("Memory used", "\(Fmt.memory(c.memoryUsedBytes)) · \(Int(used * 100))%")
                MemoryBar(fraction: used).padding(.horizontal, 12).padding(.bottom, 11)
                if let split = s.split, split.role == "coordinator" {
                    ChromeRowDivider()
                    InfoRow("Layers", split.split.enumerated().map { "\($0.element)" }.joined(separator: " + "))
                }
            }
            splitControl(s)
        }
    }

    @ViewBuilder
    private func splitControl(_ s: Status) -> some View {
        let selected = engine.local.first { $0.repo == engine.selectedRepo }
        if s.split?.role == "coordinator" {
            ChromeTextButton(symbol: "stop.fill", title: "Stop split", help: "Stop serving across Macs") { engine.stop() }
        } else if s.split == nil, s.hasPeers, let selected {
            if selected.splittable {
                ChromeTextButton(symbol: "square.split.2x1", title: "Split across \(1 + s.peers.filter { $0.reachable != false }.count) Macs",
                                 help: "Run \(Fmt.modelName(selected.repo)) with its layers spread over every Mac") {
                    engine.startSplit()
                }
            } else {
                Text(verbatim: "\(Fmt.modelName(selected.repo)) can't be split across Macs.")
                    .font(.system(size: 11.5)).foregroundStyle(Chrome.secondaryText).padding(.horizontal, 4)
            }
        }
    }
}

struct InfoRow: View {
    let title: String
    let value: String
    var tint: Color?
    var mono = false

    init(_ title: String, _ value: String, tint: Color? = nil, mono: Bool = false) {
        self.title = title
        self.value = value
        self.tint = tint
        self.mono = mono
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(verbatim: title).font(.system(size: 12.5)).foregroundStyle(Chrome.secondaryText)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12.5, weight: .medium).monospacedDigit())
                .foregroundStyle(tint ?? Chrome.primaryText)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct MemoryBar: View {
    let fraction: Double
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Chrome.overlay(0.1))
                Capsule()
                    .fill(fraction > 0.9 ? Chrome.danger : fraction > 0.75 ? Chrome.warning : Chrome.accent)
                    .frame(width: max(height, geo.size.width * min(1, fraction)))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: fraction)
    }
}
