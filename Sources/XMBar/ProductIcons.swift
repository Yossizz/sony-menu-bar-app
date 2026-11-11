import AppKit
import SwiftUI
import XMKit

// Hand-drawn product silhouettes (our own vector drawings, not Sony artwork) for the
// earbuds, their charging case, and over-ear headphones. All shapes are drawn on a
// 100×100 grid and scaled into whatever rect they're given.

private struct Grid {
    let rect: CGRect
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x / 100 * rect.width, y: rect.minY + y / 100 * rect.height)
    }
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(origin: pt(x, y), size: CGSize(width: w / 100 * rect.width, height: h / 100 * rect.height))
    }
}

// MARK: Earbud (right ear, seen from the side; mirror for left)

/// The rounded "pebble" body of a WF-series earbud.
struct EarbudBodyShape: Shape {
    func path(in rect: CGRect) -> Path {
        let g = Grid(rect: rect)
        var p = Path()
        p.move(to: g.pt(14, 46))
        p.addCurve(to: g.pt(52, 14), control1: g.pt(12, 24), control2: g.pt(32, 12))
        p.addCurve(to: g.pt(76, 40), control1: g.pt(68, 15), control2: g.pt(77, 26))
        p.addCurve(to: g.pt(56, 82), control1: g.pt(76, 60), control2: g.pt(70, 78))
        p.addCurve(to: g.pt(14, 46), control1: g.pt(36, 88), control2: g.pt(16, 70))
        p.closeSubpath()
        return p
    }
}

/// The silicone ear tip sticking out of the body.
struct EarTipShape: Shape {
    func path(in rect: CGRect) -> Path {
        let g = Grid(rect: rect)
        var p = Path()
        p.addRoundedRect(in: g.r(64, 40, 28, 30), cornerSize: CGSize(width: 0.13 * rect.width, height: 0.14 * rect.height))
        return p
    }
}

struct EarbudGlyph: View {
    var mirrored = false

    var body: some View {
        ZStack {
            EarTipShape().opacity(0.55)
            EarbudBodyShape()
            // Touch-sensor ring and mic port, cut out of the body.
            GeometryReader { geo in
                let s = min(geo.size.width, geo.size.height)
                Circle()
                    .stroke(lineWidth: max(1, s * 0.05))
                    .frame(width: s * 0.25, height: s * 0.25)
                    .position(x: geo.size.width * 0.42, y: geo.size.height * 0.46)
                    .blendMode(.destinationOut)
                Circle()
                    .frame(width: s * 0.06, height: s * 0.06)
                    .position(x: geo.size.width * 0.24, y: geo.size.height * 0.34)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: Charging case

/// A flat, rounded "pill" case with the lid seam near the top.
struct CaseShape: Shape {
    func path(in rect: CGRect) -> Path {
        let g = Grid(rect: rect)
        var p = Path()
        p.addRoundedRect(in: g.r(8, 26, 84, 50), cornerSize: CGSize(width: 0.24 * rect.width, height: 0.24 * rect.height),
                         style: .continuous)
        return p
    }
}

struct CaseGlyph: View {
    var body: some View {
        ZStack {
            CaseShape()
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                // Lid seam.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.10, y: h * 0.44))
                    p.addQuadCurve(to: CGPoint(x: w * 0.90, y: h * 0.44), control: CGPoint(x: w * 0.5, y: h * 0.47))
                }
                .stroke(lineWidth: max(1, min(w, h) * 0.035))
                .blendMode(.destinationOut)
                // Status LED.
                Circle()
                    .frame(width: w * 0.07, height: w * 0.07)
                    .position(x: w * 0.5, y: h * 0.62)
                    .blendMode(.destinationOut)
            }
        }
        .compositingGroup()
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: Over-ear headphones

struct HeadphonesGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let line = max(1.2, min(w, h) * 0.08)
            ZStack {
                // Headband.
                Path { p in
                    p.move(to: CGPoint(x: w * 0.20, y: h * 0.56))
                    p.addCurve(to: CGPoint(x: w * 0.80, y: h * 0.56),
                               control1: CGPoint(x: w * 0.16, y: h * 0.06),
                               control2: CGPoint(x: w * 0.84, y: h * 0.06))
                }
                .stroke(style: StrokeStyle(lineWidth: line, lineCap: .round))
                // Ear cups (soft ovals, slightly taller than wide).
                RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
                    .frame(width: w * 0.24, height: h * 0.40)
                    .position(x: w * 0.20, y: h * 0.68)
                RoundedRectangle(cornerRadius: w * 0.12, style: .continuous)
                    .frame(width: w * 0.24, height: h * 0.40)
                    .position(x: w * 0.80, y: h * 0.68)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

// MARK: Picking the right glyph

enum ProductKind {
    case earbuds, headphones

    init(device: PairedDevice?) {
        self = device?.isEarbuds == true ? .earbuds : .headphones
    }
}

/// The product drawn as one glyph: a pair of earbuds, or headphones.
struct ProductGlyph: View {
    let kind: ProductKind

    var body: some View {
        switch kind {
        case .headphones:
            HeadphonesGlyph()
        case .earbuds:
            // One bud reads better than a pair at menu bar size.
            EarbudGlyph()
        }
    }
}

/// Glyph for one battery part: left/right earbud, the case, or whole headphones.
struct BatteryPartGlyph: View {
    let label: String // "", "L", "R", "Case"
    let kind: ProductKind

    var body: some View {
        switch label {
        case "L": EarbudGlyph(mirrored: true)
        case "R": EarbudGlyph()
        case "Case": CaseGlyph()
        default: ProductGlyph(kind: kind)
        }
    }
}

// MARK: Menu bar image

@MainActor
enum MenuBarIcon {
    private static var cache: [ProductKind: NSImage] = [:]

    /// An 18-pt template image of the product, so macOS tints it for light/dark menu bars.
    static func image(for kind: ProductKind) -> NSImage {
        if let cached = cache[kind] { return cached }
        let renderer = ImageRenderer(content: ProductGlyph(kind: kind)
            .foregroundStyle(.black)
            .frame(width: 18, height: 18))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "headphones", accessibilityDescription: nil)!
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        cache[kind] = image
        return image
    }
}

// MARK: Debug preview

/// `XMBar --render-icons <dir>` writes a preview sheet of the glyphs (light and dark) and exits.
/// Lets the drawings be checked without opening the menu bar panel.
@MainActor
enum IconPreview {
    static func renderIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--render-icons"), i + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[i + 1])
        for dark in [false, true] {
            let sheet = HStack(spacing: 24) {
                ForEach(["", "L", "R", "Case"], id: \.self) { label in
                    VStack(spacing: 6) {
                        BatteryPartGlyph(label: label, kind: label.isEmpty ? .earbuds : .earbuds)
                            .frame(width: 64, height: 64)
                        BatteryPartGlyph(label: label, kind: label.isEmpty ? .earbuds : .earbuds)
                            .frame(width: 18, height: 18)
                    }
                }
                VStack(spacing: 6) {
                    HeadphonesGlyph().frame(width: 64, height: 64)
                    HeadphonesGlyph().frame(width: 18, height: 18)
                }
                ZStack {
                    Circle().fill(Color.accentColor)
                    ProductGlyph(kind: .earbuds).foregroundStyle(.white).frame(width: 22, height: 22)
                }
                .frame(width: 36, height: 36)
            }
            .padding(20)
            .foregroundStyle(dark ? Color.white : Color.black)
            .background(dark ? Color(white: 0.15) : Color(white: 0.95))
            let r = ImageRenderer(content: sheet)
            r.scale = 2
            if let tiff = r.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(dark ? "icons-dark.png" : "icons-light.png"))
            }
        }
        exit(0)
    }
}
