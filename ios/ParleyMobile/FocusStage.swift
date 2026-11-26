import SwiftUI

/// Protocol v12 (docs/CALL-SLIDES.md): an image slide takes the whole call screen. The screenshot
/// first shows whole, then the camera glides to the part Parley talks about (`focus`), and on to
/// the next part when the voice gets there (a later slide with the same image, `ref`). Outside the
/// part the picture dims a little and a thin ring marks it; once the camera rests, the host's sharp
/// close-up (`<id>.hd`) fades in over the zoomed pixels. Subtitles, the orb and the two call
/// buttons lie over the picture on dark gradients — the way a video player keeps its controls.
struct FocusStage: View {
    let call: CallController
    let slide: Slide
    let index: Int
    let count: Int
    let image: UIImage?
    let closeUp: UIImage?
    let name: String
    let color: Color
    let status: AnyView
    var onMinimize: () -> Void
    var onZoom: (UIImage) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the camera looks (fractions of the image); nil = the whole image.
    @State private var camera: CGRect?
    @State private var spot = 0.0
    @State private var sharp = false
    @State private var shownImage: String?

    /// Slow in, slow out — a camera move, not a bounce.
    static let glide = Animation.timingCurve(0.65, 0, 0.35, 1, duration: 1.2)

    var body: some View {
        ZStack {
            GeometryReader { outer in
                let insets = outer.safeAreaInsets
                GeometryReader { geo in
                    picture(in: geo.size, top: insets.top + 64, bottom: insets.bottom + 226)
                }
                .ignoresSafeArea()
            }
            // The dark gradients behind the bars, edge to edge (the free colour must not show
            // under them — on a light page that was a bright line at the bottom).
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 190)
                Spacer(minLength: 0)
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.55), location: 0.35),
                                       .init(color: .black.opacity(0.9), location: 1)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 340)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            bars
        }
        .environment(\.colorScheme, .dark)
        .persistentSystemOverlays(.hidden)   // no home indicator line over the picture
        .task(id: slide.id) { await move() }
    }

    // MARK: - the picture

    @ViewBuilder
    private func picture(in size: CGSize, top: CGFloat, bottom: CGFloat) -> some View {
        ZStack {
            // What the screenshot leaves free takes the colour of its edges — the page seems to go on.
            (image.map(EdgeColor.of) ?? .black)
                .animation(.easeInOut(duration: 0.4), value: slide.imageKey)
            Color.black.opacity(0.4 * spot)   // dimmed with the picture around the focus
            if let image {
                let frame = FocusCamera.frame(image: image.size, view: size, focus: camera, top: top, bottom: bottom)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image).resizable()
                    if let closeUp, let f = camera, sharp {
                        let c = FocusCamera.closeUp(f)
                        Image(uiImage: closeUp)
                            .resizable()
                            .frame(width: c.width * frame.width, height: c.height * frame.height)
                            .offset(x: c.minX * frame.width, y: c.minY * frame.height)
                            .transition(.opacity)
                    }
                    Spotlight(rect: camera ?? CGRect(x: 0, y: 0, width: 1, height: 1), strength: spot)
                        .allowsHitTesting(false)
                }
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
                .id(slide.ref ?? slide.id)
                .transition(.opacity)
                .onTapGesture { onZoom(sharp ? closeUp ?? image : image) }
                .accessibilityLabel(slide.title ?? "Bild")
                .accessibilityAddTraits(.isImage)
            } else {
                ProgressView().tint(.white)
            }
        }
        .animation(.easeInOut(duration: 0.4), value: slide.ref ?? slide.id)
    }

    /// The camera for this slide: a new image starts whole and zooms in after a beat; the same
    /// image glides from the last part to this one. The close-up follows once it rests.
    private func move() async {
        let key = slide.ref ?? slide.id
        let target = slide.focus.flatMap(FocusCamera.rect)
        withAnimation(.easeOut(duration: 0.2)) { sharp = false }
        if shownImage != key {
            shownImage = key
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { camera = nil; spot = 0 }
            if target != nil { try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 550)) }
        }
        guard !Task.isCancelled else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : Self.glide) {
            camera = target
            spot = target == nil ? 0 : 1
        }
        guard target != nil, closeUp != nil else { return }
        try? await Task.sleep(for: .milliseconds(reduceMotion ? 350 : 1250))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.5)) { sharp = true }
    }

    // MARK: - over the picture

    private var bars: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "viewfinder")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.claude)
                    Text(slide.title ?? "Bild")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if count > 1 {
                        Text("\(index + 1) / \(count)")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(.ultraThinMaterial))
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: slide.id)
                Spacer(minLength: 8)
                Button(action: onMinimize) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Bild verkleinern")
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer(minLength: 0)

            VStack(spacing: 16) {
                if call.hostAudio != .idle, let c = call.caption {
                    LiveCaption(call: call, caption: c)
                        .shadow(color: .black.opacity(0.8), radius: 6, y: 1)
                }
                HStack(spacing: 12) {
                    ParticleOrb(style: Appearance.shared.orbStyle, color: color, size: 34, paused: reduceMotion) {
                        Double(call.level(at: $0))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        status.font(.caption).monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    Button { call.setMuted(!call.muted) } label: {
                        Image(systemName: call.muted ? "mic.slash.fill" : "mic.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(call.muted ? AnyShapeStyle(Color.white) : AnyShapeStyle(.ultraThinMaterial)))
                            .foregroundStyle(call.muted ? Color.black : Color.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stumm")
                    Button { call.hangUp() } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.body.weight(.semibold))
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(Theme.danger))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Auflegen")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
    }
}

/// The camera's arithmetic, pure.
enum FocusCamera {
    /// How much of the free room the focused part fills.
    static let fill: CGFloat = 0.7

    /// `[x, y, w, h]` → a rect, if it is one.
    static func rect(_ f: [Double]) -> CGRect? {
        f.count == 4 && f[2] > 0 && f[3] > 0 ? CGRect(x: f[0], y: f[1], width: f[2], height: f[3]) : nil
    }

    /// Where the image sits on screen (its frame in view coordinates). Without a focus it fits
    /// whole between the bars (`top`, `bottom`). With one, that part fills about 70 % of the free room (the page
    /// around it stays in view), zoomed at most 5× past the fit, its centre always in the middle of the
    /// screen — near an edge of the image, the edge colour fills the rest.
    static func frame(image: CGSize, view: CGSize, focus: CGRect?, top: CGFloat, bottom: CGFloat) -> CGRect {
        guard image.width > 0, image.height > 0, view.width > 0, view.height > 0 else { return .zero }
        let free = CGRect(x: 0, y: top, width: view.width, height: max(1, view.height - top - bottom))
        let fit = min(free.width / image.width, free.height / image.height)
        var scale = fit
        if let f = focus {
            // The part takes about 70 % of the room, so some of the page around it stays in view.
            scale = min(free.width * fill / (f.width * image.width), free.height * fill / (f.height * image.height))
            scale = min(max(scale, fit), fit * 5)
        }
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        guard let f = focus else {
            return CGRect(x: free.midX - size.width / 2, y: free.midY - size.height / 2, width: size.width, height: size.height)
        }
        // The part sits in the middle of the screen (sized to fit between the bars).
        return CGRect(x: view.width / 2 - f.midX * size.width, y: view.height / 2 - f.midY * size.height,
                      width: size.width, height: size.height)
    }

    /// The host's close-up of a focus (Slides.closeUp on the Mac): the rect plus a margin.
    static func closeUp(_ f: CGRect) -> CGRect {
        let m = 0.12 * max(f.width, f.height)
        let x = max(0, f.minX - m), y = max(0, f.minY - m)
        return CGRect(x: x, y: y, width: min(1, f.maxX + m) - x, height: min(1, f.maxY + m) - y)
    }
}

/// Dims the picture outside `rect` (fractions) and rings it — both glide with the camera.
private struct Spotlight: View {
    var rect: CGRect
    var strength: Double

    var body: some View {
        ZStack {
            SpotShape(rect: rect, cutout: true)
                .fill(Color.black.opacity(0.4 * strength), style: FillStyle(eoFill: true))
            SpotShape(rect: rect, cutout: false)
                .stroke(Theme.claude.opacity(0.9 * strength), lineWidth: 2.5)
                .shadow(color: Theme.claude.opacity(0.7 * strength), radius: 10)
        }
    }
}

private struct SpotShape: Shape {
    var rect: CGRect
    var cutout: Bool

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(rect.minX, rect.minY), .init(rect.width, rect.height)) }
        set { rect = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in bounds: CGRect) -> Path {
        let pad: CGFloat = 6
        let r = CGRect(x: rect.minX * bounds.width - pad, y: rect.minY * bounds.height - pad,
                       width: rect.width * bounds.width + 2 * pad, height: rect.height * bounds.height + 2 * pad)
        var p = Path()
        if cutout { p.addRect(bounds.insetBy(dx: -1, dy: -1)) }
        p.addRoundedRect(in: r, cornerSize: CGSize(width: 12, height: 12), style: .continuous)
        return p
    }
}

/// The colour of an image's border (average of its outermost pixels at 12×12), to fill the room
/// around it. Opaque; black if it can't be read.
enum EdgeColor {
    @MainActor private static var cache: [ObjectIdentifier: Color] = [:]

    @MainActor static func of(_ image: UIImage) -> Color {
        if let c = cache[ObjectIdentifier(image)] { return c }
        let c = rgb(image).map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .black
        cache[ObjectIdentifier(image)] = c
        return c
    }

    static func rgb(_ image: UIImage) -> (r: Double, g: Double, b: Double)? {
        guard let cg = image.cgImage else { return nil }
        let n = 12
        var px = [UInt8](repeating: 0, count: n * n * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var sum = (0.0, 0.0, 0.0), count = 0.0
        for y in 0..<n { for x in 0..<n where x == 0 || y == 0 || x == n - 1 || y == n - 1 {
            let i = (y * n + x) * 4
            sum.0 += Double(px[i]); sum.1 += Double(px[i + 1]); sum.2 += Double(px[i + 2]); count += 1
        } }
        return (sum.0 / count / 255, sum.1 / count / 255, sum.2 / count / 255)
    }
}

