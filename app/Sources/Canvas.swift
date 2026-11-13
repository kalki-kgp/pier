import SwiftUI

/// This Mac at the top, the other Pier nodes in a row beneath it, each joined by its link.
struct TopologyCanvas: View {
    @ObservedObject var engine: Engine

    private let cardWidth: CGFloat = 256
    private let cardHeight: CGFloat = 200

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let peers = engine.status?.peers ?? []
            let selfCenter = CGPoint(x: size.width / 2, y: peers.isEmpty ? size.height * 0.46 : size.height * 0.3)
            let peerY = size.height * 0.72
            let spacing = min(cardWidth + 40, (size.width - 40) / CGFloat(max(peers.count, 1)))
            let peerCenters = peers.indices.map { i in
                CGPoint(x: size.width / 2 + (CGFloat(i) - CGFloat(peers.count - 1) / 2) * spacing, y: peerY)
            }

            ZStack {
                DotGrid()

                ForEach(Array(peers.enumerated()), id: \.element.id) { i, peer in
                    let from = CGPoint(x: selfCenter.x, y: selfCenter.y + cardHeight / 2)
                    let to = CGPoint(x: peerCenters[i].x, y: peerCenters[i].y - cardHeight / 2)
                    Link(from: from, to: to)
                        .stroke(Chrome.accent.opacity(peer.reachable == false ? 0.25 : 0.7),
                                style: StrokeStyle(lineWidth: 1.6, lineCap: .round,
                                                   dash: peer.reachable == false ? [4, 5] : []))
                    LinkLabel(peer: peer)
                        .position(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                }

                if let node = engine.status?.node {
                    NodeCard(node: node, isThisMac: true, serving: node.model)
                        .frame(width: cardWidth, height: cardHeight)
                        .position(selfCenter)
                    ForEach(Array(peers.enumerated()), id: \.element.id) { i, peer in
                        NodeCard(node: peer.info, isThisMac: false, serving: peer.info.model,
                                 dimmed: peer.reachable == false)
                            .frame(width: cardWidth, height: cardHeight)
                            .position(peerCenters[i])
                            .transition(.softAppear)
                    }
                    if peers.isEmpty {
                        Text("Other Macs running Pier on your network show up here.")
                            .font(.system(size: 12))
                            .foregroundStyle(Chrome.secondaryText)
                            .position(x: size.width / 2, y: selfCenter.y + cardHeight / 2 + 34)
                    }
                } else {
                    VStack(spacing: 10) {
                        if engine.problem == nil { ProgressView().controlSize(.small) }
                        Text(engine.problem == nil ? "Starting the engine…" : "The engine isn't running")
                            .font(.system(size: 12.5)).foregroundStyle(Chrome.secondaryText)
                    }
                }
            }
            .animation(Chrome.panelSlide, value: peers.map(\.id))
        }
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            let dot = Path(ellipseIn: CGRect(x: 0, y: 0, width: 2, height: 2))
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    ctx.fill(dot.offsetBy(dx: x - 1, dy: y - 1), with: .color(Chrome.overlay(0.11)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

/// An elbow: down, across with rounded corners, down.
struct Link: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in _: CGRect) -> Path {
        var p = Path()
        let midY = (from.y + to.y) / 2
        let dx = to.x - from.x
        let r = min(18, abs(dx) / 2, abs(midY - from.y))
        p.move(to: from)
        if abs(dx) < 1 {
            p.addLine(to: to)
            return p
        }
        let sx: CGFloat = dx > 0 ? 1 : -1
        p.addLine(to: CGPoint(x: from.x, y: midY - r))
        p.addQuadCurve(to: CGPoint(x: from.x + sx * r, y: midY), control: CGPoint(x: from.x, y: midY))
        p.addLine(to: CGPoint(x: to.x - sx * r, y: midY))
        p.addQuadCurve(to: CGPoint(x: to.x, y: midY + r), control: CGPoint(x: to.x, y: midY))
        p.addLine(to: to)
        return p
    }
}

struct LinkLabel: View {
    let peer: Peer

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            Text(verbatim: title).font(.system(size: 10.5, weight: .semibold))
            if let ms = peer.latencyMs, peer.link != "same" {
                Text(verbatim: String(format: "%.0f ms", ms)).font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Chrome.secondaryText)
            }
        }
        .foregroundStyle(Chrome.primaryText.opacity(0.85))
        .padding(.horizontal, 9)
        .frame(height: 22)
        .glassEffect(.regular, in: Capsule(style: .continuous))
    }

    private var title: String {
        switch peer.link {
        case "thunderbolt": "TB"
        case "wifi": "Wi-Fi"
        case "ethernet": "Ethernet"
        case "same": "Same Mac"
        default: "Network"
        }
    }

    private var symbol: String {
        switch peer.link {
        case "thunderbolt": "bolt.fill"
        case "wifi": "wifi"
        case "same": "arrow.triangle.2.circlepath"
        default: "network"
        }
    }
}

struct NodeCard: View {
    let node: NodeInfo
    let isThisMac: Bool
    let serving: String?
    var dimmed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let used = node.memoryBytes > 0 ? Double(node.memoryUsedBytes) / Double(node.memoryBytes) : 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, hue: isThisMac ? 5 : 2, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: node.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    Text(verbatim: isThisMac ? "This Mac" : dimmed ? "Not answering" : node.host)
                        .font(.system(size: 11)).foregroundStyle(Chrome.secondaryText).lineLimit(1)
                }
            }
            .padding(.bottom, 12)
            spec("Chip", node.chip)
            spec("Memory", Fmt.memory(node.memoryBytes))
            spec("SSD", Fmt.disk(node.diskBytes))
            spec("Model", serving.map(Fmt.modelName) ?? "None")
            if let layers = node.layers, layers.count == 2 {
                spec("Layers", "\(layers[0])–\(layers[1])")
            }
            MemoryBar(fraction: used, height: 4).padding(.top, 8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: shape)
        .overlay {
            if isThisMac { shape.strokeBorder(Chrome.accent.opacity(0.55), lineWidth: 1.5) }
        }
        .opacity(dimmed ? 0.55 : 1)
    }

    private func spec(_ label: String, _ value: String) -> some View {
        HStack {
            Text(verbatim: label).foregroundStyle(Chrome.secondaryText)
            Spacer(minLength: 10)
            Text(verbatim: value).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.vertical, 2.5)
    }

    private var symbol: String {
        switch node.kind {
        case "mini": "macmini"
        case "studio": "macstudio"
        case "imac": "desktopcomputer"
        case "pro": "macpro.gen3"
        default: "laptopcomputer"
        }
    }
}
