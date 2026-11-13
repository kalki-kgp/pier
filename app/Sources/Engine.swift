import AppKit
import Foundation

// MARK: - Wire types (pierd's JSON, snake_case)

struct TBPort: Codable, Equatable { let id: String?; let gbps: Int?; let generation: Int?; let connected: Bool }

struct NodeInfo: Codable, Equatable {
    let id: String
    let port: Int
    let name: String
    let host: String
    let modelId: String
    let kind: String
    let chip: String
    let cpuCores: Int
    let gpuCores: Int?
    let memoryBytes: Int64
    let diskBytes: Int64
    let thunderbolt: [TBPort]
    let memoryUsedBytes: Int64
    let gpuBudgetBytes: Int64
    let model: String?
    let modelState: String
    let role: String?
    let layers: [Int]?
}

struct SplitInfo: Codable, Equatable {
    let role: String
    let rank: Int
    let state: String
    let error: String?
    let layers: [Int]?
    let repo: String
    let split: [Int]
}

struct ServerInfo: Codable, Equatable { let port: Int; let endpoint: String; let startedAt: Double; let mode: String }

struct RuntimeInfo: Codable, Equatable {
    let state: String
    let error: String?
    let repo: String?
    let loadedAt: Double?
    let weightsBytes: Int64
    let active: Int
    let queued: Int
    let served: Int
    let tokensOut: Int
    let lastTps: Double?
    let lastPromptTps: Double?
    let peakBytes: Int64
    let metalActiveBytes: Int64
}

struct HardwareInfo: Codable, Equatable {
    let thunderboltPorts: Int
    let thunderboltGeneration: Int?
    let rdma: String
    let diskFreeBytes: Int64
}

struct Peer: Codable, Equatable, Identifiable {
    let id: String
    let ip: String
    let port: Int
    let link: String
    let info: NodeInfo
    let reachable: Bool?
    let latencyMs: Double?
}

struct ClusterInfo: Codable, Equatable { let nodes: Int; let machines: Int; let memoryBytes: Int64; let memoryUsedBytes: Int64 }

struct Download: Codable, Equatable, Identifiable {
    var id: String { repo }
    let repo: String
    let total: Int64?
    let done: Int64
    let state: String
    let error: String?
    var fraction: Double { guard let total, total > 0 else { return 0 }; return min(1, Double(done) / Double(total)) }
}

struct Status: Codable, Equatable {
    let node: NodeInfo
    let server: ServerInfo
    let runtime: RuntimeInfo
    let hardware: HardwareInfo
    let peers: [Peer]
    let cluster: ClusterInfo
    let downloads: [Download]
    let split: SplitInfo?

    /// Model memory across this Mac and every peer that answers (a peer on this same Mac too,
    /// since that's how a split is tested before a second Mac exists).
    var clusterBudget: Int64 {
        node.gpuBudgetBytes + peers.filter { $0.reachable != false }.reduce(0) { $0 + $1.info.gpuBudgetBytes }
    }
    var hasPeers: Bool { peers.contains { $0.reachable != false } }
}

struct LocalModel: Codable, Equatable, Identifiable {
    var id: String { repo }
    let repo: String
    let sizeBytes: Int64
    let diskBytes: Int64
    let fit: String
    let splittable: Bool
}

struct CatalogModel: Codable, Equatable, Identifiable {
    var id: String { repo }
    let repo: String
    let sizeBytes: Int64?
    let downloads: Int
    let likes: Int
    let fit: String
    let downloaded: Bool
    let downloading: Bool
    let splittable: Bool
}

// MARK: - Engine

/// Starts pierd if nothing is listening, polls it, and sends it commands.
@MainActor
final class Engine: ObservableObject {
    @Published private(set) var status: Status?
    @Published private(set) var local: [LocalModel] = []
    @Published private(set) var connected = false
    @Published var problem: String?
    @Published var selectedRepo: String? {
        didSet { UserDefaults.standard.set(selectedRepo, forKey: "selectedRepo") }
    }

    let port: Int
    private var process: Process?
    private let session: URLSession
    private var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private var lastDownloadCount = 0

    init() {
        port = Int(ProcessInfo.processInfo.environment["PIER_PORT"] ?? "") ?? 52500
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config)
        selectedRepo = UserDefaults.standard.string(forKey: "selectedRepo")
        Task { await run() }
    }

    /// The Python and engine to run: the copy inside the app (release builds), else a dev
    /// checkout's venv (PIER_ENGINE, ../engine beside the app, or ~/Developer/pier/engine).
    private var engineLaunch: (python: URL, dir: URL, env: [String: String])? {
        let fm = FileManager.default
        if let res = Bundle.main.resourceURL {
            let python = res.appendingPathComponent("python/bin/python3.13")
            let engine = res.appendingPathComponent("engine")
            if fm.isExecutableFile(atPath: python.path) {
                return (python, engine, ["PYTHONPATH": "\(engine.path):\(engine.path)/site-packages",
                                         "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"])
            }
        }
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["PIER_ENGINE"] { candidates.append(URL(fileURLWithPath: env)) }
        candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("engine"))
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Developer/pier/engine"))
        for dir in candidates {
            let python = dir.appendingPathComponent(".venv/bin/python")
            if fm.isExecutableFile(atPath: python.path) { return (python, dir, [:]) }
        }
        return nil
    }

    private func run() async {
        if await fetchStatus() == false { launch() }
        var tick = 0
        while true {
            let ok = await fetchStatus()
            if ok && (tick % 3 == 0 || (status?.downloads.count ?? 0) != lastDownloadCount) {
                lastDownloadCount = status?.downloads.count ?? 0
                await refreshLocal()
            }
            if !ok, process == nil || process?.isRunning == false, tick > 3 { launch() }
            tick += 1
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func launch() {
        guard let (python, dir, extra) = engineLaunch else {
            problem = "Can't find Pier's engine"
            return
        }
        let p = Process()
        p.executableURL = python
        p.arguments = ["-m", "pierd"]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env.merge(extra) { _, new in new }
        env["PIER_PARENT_PID"] = String(getpid())
        env["PIER_PORT"] = String(port)
        p.environment = env
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Pier")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("pierd.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            p.standardOutput = handle
            p.standardError = handle
        }
        do {
            try p.run()
            process = p
        } catch {
            problem = "The engine didn't start: \(error.localizedDescription)"
        }
    }

    func shutdown() {
        process?.terminate()
    }

    // MARK: Reads

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let (data, _) = try await session.data(from: URL(string: path, relativeTo: base)!)
        return try Self.decoder.decode(T.self, from: data)
    }

    @discardableResult
    private func fetchStatus() async -> Bool {
        do {
            let s = try await get("/pier/status", as: Status.self)
            if s != status { status = s }
            // The picker follows whatever is actually being served, however it was started.
            if s.runtime.state == "ready", let repo = s.runtime.repo, repo != selectedRepo { selectedRepo = repo }
            if !connected { connected = true; problem = nil }
            return true
        } catch {
            connected = false
            return false
        }
    }

    func refreshLocal() async {
        guard let models = try? await get("/pier/models/local", as: [LocalModel].self) else { return }
        if models != local { local = models }
        if selectedRepo == nil || !models.contains(where: { $0.repo == selectedRepo }) {
            selectedRepo = status?.runtime.repo ?? models.first(where: { $0.fit != "too_big" })?.repo ?? models.first?.repo
        }
    }

    func search(_ query: String) async throws -> [CatalogModel] {
        var c = URLComponents(string: "/pier/models/search")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "40")]
        var req = URLRequest(url: c.url(relativeTo: base)!)
        req.timeoutInterval = 20
        let (data, _) = try await session.data(for: req)
        return try Self.decoder.decode([CatalogModel].self, from: data)
    }

    // MARK: Commands

    private func post(_ path: String, _ body: [String: String] = [:]) async {
        var req = URLRequest(url: URL(string: path, relativeTo: base)!)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let err = obj["error"] as? [String: Any], let message = err["message"] as? String {
                problem = message
            }
        } catch {
            problem = error.localizedDescription
        }
        await fetchStatus()
        await refreshLocal()
    }

    func start() {
        guard let repo = selectedRepo else { return }
        Task { await post("/pier/load", ["repo": repo]) }
    }

    func stop() {
        if status?.split?.role == "coordinator" { Task { await post("/pier/cluster/stop") } }
        else { Task { await post("/pier/unload") } }
    }

    func startSplit() {
        guard let repo = selectedRepo else { return }
        Task { await post("/pier/cluster/start", ["repo": repo]) }
    }

    /// Whether a model of this size fits once split across every Mac that answers.
    func fitsCluster(_ bytes: Int64?, splittable: Bool) -> Bool {
        guard splittable, let bytes, let status, status.hasPeers else { return false }
        return Double(bytes) * 1.15 <= Double(status.clusterBudget)
    }

    func select(_ repo: String) {
        selectedRepo = repo
        // Switching while serving swaps the model in place.
        if let rt = status?.runtime, rt.state == "ready", rt.repo != repo {
            if status?.split?.role == "coordinator" { startSplit() } else { start() }
        }
    }

    func download(_ repo: String) { Task { await post("/pier/models/download", ["repo": repo]) } }
    func cancel(_ repo: String) { Task { await post("/pier/models/cancel", ["repo": repo]) } }
    func delete(_ repo: String) { Task { await post("/pier/models/delete", ["repo": repo]) } }
}

// MARK: - Formatting

enum Fmt {
    /// RAM in the binary units Apple sells it in: 16 GB, 24 GB.
    static func memory(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 10 || gb.rounded() == gb ? "\(Int(gb.rounded())) GB" : String(format: "%.1f GB", gb)
    }

    /// A disk's marketed size: the reported capacity rounds up to the next tier (245 → 256 GB).
    static func disk(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1e9
        for tier in [64.0, 128, 256, 512, 1024, 2048, 4096, 8192] where gb <= tier * 1.0 {
            return tier >= 1024 ? "\(Int(tier / 1024)) TB" : "\(Int(tier)) GB"
        }
        return String(format: "%.0f TB", gb / 1000)
    }

    static func size(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let gb = Double(bytes) / 1e9
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", gb * 1000)
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func count(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6)
            : n >= 1000 ? String(format: "%.1fK", Double(n) / 1e3) : "\(n)"
    }

    /// "mlx-community/Qwen3-0.6B-4bit" → "Qwen3-0.6B-4bit"
    static func modelName(_ repo: String) -> String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }
}
