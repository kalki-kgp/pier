import SwiftUI

/// Search mlx-community, download, load, delete.
struct ModelBrowser: View {
    @ObservedObject var engine: Engine
    @Binding var isPresented: Bool

    @State private var query = ""
    @State private var results: [CatalogModel] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Chrome.secondaryText)
                    TextField("Search mlx-community", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .onSubmit { runSearch(immediately: true) }
                    if searching { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 14)
                .frame(height: Chrome.capsuleHeight)
                .chromeGlassCapsule()
                ChromeCircleButton(symbol: "xmark", help: "Back to the cluster") { isPresented = false }
            }
            .frame(maxWidth: 720)

            ScrollView {
                VStack(alignment: .leading, spacing: Chrome.sectionSpacing) {
                    let downloading = engine.status?.downloads ?? []
                    if !engine.local.isEmpty || !downloading.isEmpty {
                        ChromeSection(title: "On this Mac") {
                            ChromeCard {
                                ForEach(Array(downloading.enumerated()), id: \.element.id) { i, d in
                                    if i > 0 { ChromeRowDivider(inset: 54) }
                                    DownloadRow(download: d, engine: engine)
                                }
                                ForEach(Array(engine.local.enumerated()), id: \.element.id) { i, m in
                                    if i > 0 || !downloading.isEmpty { ChromeRowDivider(inset: 54) }
                                    LocalRow(model: m, engine: engine, close: { isPresented = false })
                                }
                            }
                        }
                    }
                    ChromeSection(title: query.isEmpty ? "Popular" : "Results") {
                        ChromeCard {
                            if let searchError {
                                ChromeRow(title: "Couldn't reach Hugging Face", detail: searchError) { EmptyView() }
                            } else if results.isEmpty && !searching {
                                ChromeRow(title: "Nothing matches “\(query)”") { EmptyView() }
                            }
                            let localRepos = Set(engine.local.map(\.repo))
                            let active = Set((engine.status?.downloads ?? []).map(\.repo))
                            let rows = results.filter { !localRepos.contains($0.repo) && !active.contains($0.repo) }
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, m in
                                if i > 0 { ChromeRowDivider(inset: 54) }
                                CatalogRow(model: m, engine: engine)
                            }
                        }
                    }
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .onAppear { runSearch(immediately: true) }
        .onChange(of: query) { runSearch(immediately: false) }
    }

    private func runSearch(immediately: Bool) {
        searchTask?.cancel()
        searchTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(350)) }
            if Task.isCancelled { return }
            searching = true
            defer { searching = false }
            do {
                let found = try await engine.search(query)
                if !Task.isCancelled { results = found; searchError = nil }
            } catch {
                if !Task.isCancelled { searchError = error.localizedDescription }
            }
        }
    }
}

private func fitText(_ fit: String) -> (String, Color?) {
    switch fit {
    case "fits": ("Fits", nil)
    case "tight": ("Tight fit", Chrome.warning)
    case "too_big": ("Too big for this Mac", Chrome.danger)
    default: ("", nil)
    }
}

struct CatalogRow: View {
    let model: CatalogModel
    @ObservedObject var engine: Engine

    var body: some View {
        let needsCluster = model.fit == "too_big" && engine.fitsCluster(model.sizeBytes, splittable: model.splittable)
        let (fit, tint) = needsCluster ? ("Needs the cluster", Chrome.accent) : fitText(model.fit)
        HStack(spacing: 12) {
            IconTile(symbol: "cube.fill", hue: 3, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Fmt.modelName(model.repo)).font(.system(size: 13)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: Fmt.size(model.sizeBytes))
                    Text(verbatim: "·")
                    Text(verbatim: "\(Fmt.count(model.downloads)) downloads")
                    if !fit.isEmpty {
                        Text(verbatim: "·")
                        Text(verbatim: fit).foregroundStyle(tint ?? Chrome.secondaryText)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Chrome.secondaryText)
            }
            Spacer(minLength: 12)
            ChromeTextButton(symbol: "arrow.down", title: "Download", help: "Download \(Fmt.modelName(model.repo))",
                             isEnabled: model.fit != "too_big" || needsCluster) {
                engine.download(model.repo)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 9)
    }
}

struct DownloadRow: View {
    let download: Download
    @ObservedObject var engine: Engine

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(Chrome.overlay(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: download.fraction)
                    .stroke(Chrome.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.smooth(duration: 0.4), value: download.fraction)
            }
            .frame(width: 24, height: 24)
            .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Fmt.modelName(download.repo)).font(.system(size: 13)).lineLimit(1)
                Text(verbatim: detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(download.state == "failed" ? Chrome.danger : Chrome.secondaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            ChromeTextButton(symbol: "xmark", title: download.state == "failed" ? "Dismiss" : "Cancel",
                             help: "Stop this download") {
                engine.cancel(download.repo)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 9)
    }

    private var detail: String {
        switch download.state {
        case "failed": return download.error ?? "Download failed"
        case "starting": return "Starting…"
        case "done": return "Done"
        default: return "\(Fmt.size(download.done)) of \(Fmt.size(download.total)) · \(Int(download.fraction * 100))%"
        }
    }
}

struct LocalRow: View {
    let model: LocalModel
    @ObservedObject var engine: Engine
    let close: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        let needsCluster = model.fit == "too_big" && engine.fitsCluster(model.sizeBytes, splittable: model.splittable)
        let (fit, tint) = needsCluster ? ("Needs the cluster", Chrome.accent) : fitText(model.fit)
        let isLoaded = engine.status?.runtime.repo == model.repo
        HStack(spacing: 12) {
            IconTile(symbol: "cube.fill", hue: isLoaded ? 4 : 5, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: Fmt.modelName(model.repo)).font(.system(size: 13)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(verbatim: Fmt.size(model.sizeBytes))
                    if isLoaded {
                        Text(verbatim: "·")
                        Text(verbatim: "Serving")
                    } else if model.fit != "fits" && !fit.isEmpty {
                        Text(verbatim: "·")
                        Text(verbatim: fit).foregroundStyle(tint ?? Chrome.secondaryText)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Chrome.secondaryText)
            }
            Spacer(minLength: 12)
            if !isLoaded {
                ChromeTextButton(symbol: "play.fill", title: needsCluster ? "Split" : "Serve",
                                 help: needsCluster ? "Serve it split across your Macs" : "Load and serve this model",
                                 isEnabled: model.fit != "too_big" || needsCluster) {
                    engine.selectedRepo = model.repo
                    if needsCluster { engine.startSplit() } else { engine.start() }
                    close()
                }
                ChromeCircleButton(symbol: "trash", help: "Delete from this Mac") { confirmDelete = true }
                    .popover(isPresented: $confirmDelete, arrowEdge: .bottom) {
                        PopoverMenu {
                            PopoverSectionHeader("Frees \(Fmt.size(model.diskBytes))")
                            PopoverItem("Delete \(Fmt.modelName(model.repo))") { engine.delete(model.repo) }
                        }
                    }
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, Chrome.rowControlTrailingPadding)
        .padding(.vertical, 9)
    }
}
