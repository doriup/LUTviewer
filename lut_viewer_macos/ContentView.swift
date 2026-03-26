import SwiftUI
import AppKit
import Charts
import UniformTypeIdentifiers
import ImageIO

// MARK: - AppState

final class AppState: ObservableObject {

    // MARK: Image state
    @Published var loadedImage:   LoadedImage?   // full-precision source
    @Published var loadedImageLUT: LoadedImage?  // LUT-applied version

    // Backward compat for BeforeAfterSwipeView (SDR NSImage)
    var imageOriginal: NSImage? {
        guard let l = loadedImage else { return nil }
        return NSImage(cgImage: l.cgImage, size: NSSize(width: l.width, height: l.height))
    }
    var imageLUT: NSImage? {
        guard let l = loadedImageLUT else { return nil }
        return NSImage(cgImage: l.cgImage, size: NSSize(width: l.width, height: l.height))
    }

    // MARK: HDR
    @Published var isHDRSource:   Bool = false   // loaded file is HDR
    @Published var hdrEnabled:    Bool = false   // user toggle
    var screenSupportsHDR: Bool {
        NSScreen.main.map { $0.maximumExtendedDynamicRangeColorComponentValue > 1.0 } ?? false
    }
    /// Show the HDR toggle only when source is HDR AND display supports it
    var showHDRToggle: Bool { isHDRSource && screenSupportsHDR }

    // MARK: LUT state
    @Published var lutPrimary:          CubeLUT?
    @Published var lutSecondary:        CubeLUT?
    @Published var lutComposed:         CubeLUT?
    @Published var lutFileNamePrimary:  String?
    @Published var lutFileNameSecondary: String?
    @Published var showLUTDecision:     Bool = false
    private var pendingLUT:             CubeLUT?
    private var pendingLUTFileName:     String?

    // MARK: UI
    @Published var split:         CGFloat = 0.5
    @Published var errorMessage:  String?
    let interpolationType: CubeLUT.InterpolationType = .tetrahedral

    // MARK: Reference
    @Published var currentReference:    ReferenceItem?   // active bundled reference
    @Published var referenceLUTFileName: String?         // LUT used for this reference

    private let refLib = ReferenceLibrary.shared
    private let applier  = LUTApplier()
    private let loader   = ImageLoader()

    // MARK: - LUT helpers

    var chainLUTs: [CubeLUT] {
        if let a = lutPrimary, let b = lutSecondary { return [a, b] }
        if let a = lutPrimary { return [a] }
        return []
    }
    var uiLUT: CubeLUT? { lutComposed ?? lutPrimary }

    var mergedDisplayName: String {
        let a = lutFileNamePrimary  ?? "LUT 1"
        let b = lutFileNameSecondary ?? "LUT 2"
        return lutSecondary != nil ? "\(a) + \(b)" : a
    }

    // MARK: - Actions

    func clearLUT() {
        lutPrimary = nil; lutSecondary = nil; lutComposed = nil
        lutFileNamePrimary = nil; lutFileNameSecondary = nil
        pendingLUT = nil; pendingLUTFileName = nil
        showLUTDecision = false
        loadedImageLUT  = nil
        errorMessage    = nil
        clearReference()
    }

    func clearImage() {
        loadedImage = nil
        isHDRSource = false
        clearReference()
        recompute()
    }

    func openImage() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.png, .jpeg, .tiff, .bmp]
        if let exr = UTType(filenameExtension: "exr") { types.append(exr) }
        if let dpx = UTType(filenameExtension: "dpx") { types.append(dpx) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        if panel.runModal() == .OK, let url = panel.url { loadImage(url: url) }
    }

    func openLUT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.cube]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        if panel.runModal() == .OK, let url = panel.url { loadLUT(url: url) }
    }

    func loadImage(url: URL) {
        do {
            let li = try loader.load(url: url)
            loadedImage   = li
            isHDRSource   = li.isHDR
            // Auto-enable HDR display when file is HDR and screen supports it
            hdrEnabled    = li.isHDR && screenSupportsHDR
            errorMessage  = nil
            recompute()
        } catch {
            errorMessage = "Erreur image: \(error.localizedDescription)"
        }
    }

    func loadLUT(url: URL) {
        do {
            let loaded = try CubeParser.load(from: url)
            if lutPrimary == nil {
                lutPrimary         = loaded
                lutFileNamePrimary = url.lastPathComponent
                lutSecondary       = nil
                lutFileNameSecondary = nil
                lutComposed        = nil
                errorMessage       = nil
                recompute()
                return
            }
            pendingLUT         = loaded
            pendingLUTFileName = url.lastPathComponent
            showLUTDecision    = true
            errorMessage       = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmReplaceWithPendingLUT() {
        guard let p = pendingLUT else { return }
        lutPrimary           = p
        lutFileNamePrimary   = pendingLUTFileName
        lutSecondary         = nil; lutFileNameSecondary = nil; lutComposed = nil
        pendingLUT           = nil; pendingLUTFileName   = nil
        showLUTDecision      = false
        recompute()
    }

    func confirmMergePendingLUT() {
        guard let p = pendingLUT else { return }
        lutSecondary         = p
        lutFileNameSecondary = pendingLUTFileName
        if let a = lutPrimary {
            lutComposed = CubeLUT.composed(a, p, interpolation: interpolationType)
        }
        pendingLUT = nil; pendingLUTFileName = nil; showLUTDecision = false
        recompute()
    }

    func cancelPendingLUT() {
        pendingLUT = nil; pendingLUTFileName = nil; showLUTDecision = false
    }

    func handleDrop(url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "cube" { loadLUT(url: url); return }
        if ImageLoader.supportedExtensions.contains(ext) || ext == "dpx" {
            loadImage(url: url)
            return
        }
        errorMessage = "Format non supporté : .\(ext)"
    }

    // MARK: - Reference

    func loadReferenceImage(_ item: ReferenceItem) {
        guard let imgURL = refLib.imageURL(for: item) else {
            errorMessage = "Image de référence introuvable dans le bundle."
            return
        }
        do {
            let li = try loader.load(url: imgURL)
            loadedImage   = li
            isHDRSource   = li.isHDR
            hdrEnabled    = li.isHDR && screenSupportsHDR
            currentReference = item
            errorMessage  = nil
            recompute()
        } catch {
            errorMessage = "Erreur image référence : \(error.localizedDescription)"
        }
    }

    func loadReferenceLUT(fileName: String, space: ReferenceSpace) {
        guard let base = Bundle.main.url(forResource: "ReferenceLUTs", withExtension: nil) else { return }
        
        var lutURL = base.appendingPathComponent(space.rawValue).appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: lutURL.path) {
            lutURL = base.appendingPathComponent(fileName)
        }
        
        if FileManager.default.fileExists(atPath: lutURL.path) {
            do {
                let lut = try CubeParser.load(from: lutURL)
                lutPrimary         = lut
                lutFileNamePrimary = fileName
                lutSecondary       = nil
                lutFileNameSecondary = nil
                lutComposed        = nil
                referenceLUTFileName = fileName
                errorMessage        = nil
                recompute()
            } catch {
                errorMessage = "Erreur LUT référence : \(error.localizedDescription)"
            }
        } else {
            errorMessage = "LUT de référence introuvable."
        }
    }

    func clearReference() {
        currentReference     = nil
        referenceLUTFileName = nil
    }

    // MARK: - Export

    func presentExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.cube]
        panel.nameFieldStringValue = mergedDisplayName
        panel.title = "Export Global LUT"
        panel.message = "Choose destination and LUT resolution"

        var selectedSize = LUTExportSize.s33
        
        let accessory = NSHostingView(rootView: ExportOptionsView(size: Binding(
            get: { selectedSize },
            set: { selectedSize = $0 }
        )))
        accessory.frame = NSRect(x: 0, y: 0, width: 220, height: 44)
        panel.accessoryView = accessory

        if panel.runModal() == .OK, let url = panel.url {
            do {
                let text = try LUTExporter().buildCubeText(
                    luts: chainLUTs,
                    size: selectedSize,
                    name: panel.nameFieldStringValue
                )
                try text.write(to: url, atomically: true, encoding: .utf8)
                self.errorMessage = nil
            } catch {
                self.errorMessage = "Export failed: \(error.localizedDescription)"
            }
        }
    }

    func recompute() {
        guard let li = loadedImage else { loadedImageLUT = nil; return }
        let luts = chainLUTs
        guard !luts.isEmpty else { loadedImageLUT = nil; return }
        loadedImageLUT = applier.applyChain(luts: luts, to: li)
    }

    // MARK: - Curve

    func curveSamples(count: Int = 256) -> [CurvePoint] {
        guard let lut = uiLUT else { return [] }
        var pts: [CurvePoint] = []
        pts.reserveCapacity(count * 3)
        for i in 0..<count {
            let t   = Float(i) / Float(count - 1)
            let out = lut.sample(r: t, g: t, b: t, type: interpolationType)
            pts.append(CurvePoint(t: Double(t), channel: "R", y: Double(out.x)))
            pts.append(CurvePoint(t: Double(t), channel: "G", y: Double(out.y)))
            pts.append(CurvePoint(t: Double(t), channel: "B", y: Double(out.z)))
        }
        return pts
    }
}

// MARK: - CurvePoint

struct CurvePoint: Identifiable {
    let id = UUID()
    let t: Double; let channel: String; let y: Double
}

// MARK: - BeforeAfterSwipeView (HDR-aware)

struct BeforeAfterSwipeView: View {
    let beforeLoaded: LoadedImage
    let afterLoaded:  LoadedImage?
    let hdrEnabled:   Bool
    @Binding var split: CGFloat

    private var beforeNS: NSImage {
        NSImage(cgImage: beforeLoaded.cgImage,
                size: NSSize(width: beforeLoaded.width, height: beforeLoaded.height))
    }
    private var afterNS: NSImage {
        let l = afterLoaded ?? beforeLoaded
        return NSImage(cgImage: l.cgImage, size: NSSize(width: l.width, height: l.height))
    }

    var body: some View {
        GeometryReader { geo in
            let w      = max(geo.size.width, 1)
            let h      = geo.size.height
            let s      = min(max(split, 0), 1)
            let splitX = w * s

            ZStack {
                if hdrEnabled {
                    HDRImageView(image: afterLoaded ?? beforeLoaded, hdrEnabled: true)
                        .frame(width: w, height: h)
                        .clipped()

                    HDRImageView(image: beforeLoaded, hdrEnabled: true)
                        .frame(width: w, height: h)
                        .clipped()
                        .mask(
                            Rectangle()
                                .frame(width: splitX, height: h)
                                .position(x: splitX / 2, y: h / 2)
                        )
                } else {
                    Image(nsImage: afterNS)
                        .resizable()
                        .scaledToFit()
                        .frame(width: w, height: h)

                    Image(nsImage: beforeNS)
                        .resizable()
                        .scaledToFit()
                        .frame(width: w, height: h)
                        .mask(
                            Rectangle()
                                .frame(width: splitX, height: h)
                                .position(x: splitX / 2, y: h / 2)
                        )
                }

                Rectangle()
                    .frame(width: 2, height: h)
                    .position(x: splitX, y: h / 2)

                label("Original", at: CGPoint(x: max(60, splitX - 60), y: 20))
                    .opacity(splitX < 120 ? 0 : 1)
                label("LUT",      at: CGPoint(x: min(w - 40, splitX + 40), y: 20))
                    .opacity(splitX > w - 80 ? 0 : 1)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                split = min(max(v.location.x / w, 0), 1)
            })
        }
    }

    @ViewBuilder
    private func label(_ text: String, at pt: CGPoint) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .position(x: pt.x, y: pt.y)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var state     = AppState()
    @State private var isDropTarget    = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 12) {
                toolbarRow

                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(isDropTarget ? 0.22 : 0.15))

                    if let before = state.loadedImage {
                        BeforeAfterSwipeView(
                            beforeLoaded: before,
                            afterLoaded:  state.loadedImageLUT,
                            hdrEnabled:   state.hdrEnabled,
                            split:        $state.split
                        )
                        .padding(8)
                    } else {
                        Text("Drag & drop an image or LUT here\n(.jpg, .png, .tiff, .exr, .dpx, .cube)")
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(minHeight: 450)
                .onDrop(of: [UTType.fileURL], isTargeted: $isDropTarget) { providers in
                    guard let item = providers.first else { return false }
                    item.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                        guard let data = data as? Data,
                               let url  = URL(dataRepresentation: data, relativeTo: nil) else { return }
                        DispatchQueue.main.async { state.handleDrop(url: url) }
                    }
                    return true
                }

                .alert("Second LUT :", isPresented: $state.showLUTDecision) {
                    Button("Replace LUT") { state.confirmReplaceWithPendingLUT() }
                    Button("Stack LUTs")  { state.confirmMergePendingLUT() }
                    Button("Cancel", role: .cancel) { state.cancelPendingLUT() }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                lutInfoSection
                Spacer(minLength: 0)
                chartSection
            }
            .frame(width: 380)
        }
        .padding(12)
    }

    @ViewBuilder
    private var toolbarRow: some View {
        HStack {
            Button("Open Image") { state.openImage() }
            Button("Clear Image") { state.clearImage() }
                .disabled(state.loadedImage == nil)
            
            Button("Open LUT")   { state.openLUT() }
            Button("Clear LUT")  { state.clearLUT() }
                .disabled(state.lutPrimary == nil && state.lutSecondary == nil)
            Button("Export LUT") { state.presentExportPanel() }
                .disabled(state.chainLUTs.isEmpty)

            if state.isHDRSource {
                Label("HDR", systemImage: "sun.max.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.orange.opacity(0.15), in: Capsule())
            }
            if state.showHDRToggle {
                Toggle("Affichage HDR", isOn: $state.hdrEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }

            Spacer()

            if let msg = state.errorMessage {
                Text(msg).foregroundColor(.red).font(.system(size: 12))
            }

            let imagesGrouped = ReferenceLibrary.shared.itemsBySpace()
            let lutsGrouped   = ReferenceLibrary.shared.allAvailableLUTsBySpace()
            
            Menu("References") {
                if imagesGrouped.isEmpty && lutsGrouped.isEmpty {
                    Text("Aucune référence dans le bundle")
                        .foregroundColor(.secondary)
                } else {
                    Section("Images") {
                        ForEach(imagesGrouped, id: \.space) { group in
                            if group.items.count == 1, let item = group.items.first {
                                Button(group.space.label) {
                                    state.loadReferenceImage(item)
                                }
                            } else {
                                Menu(group.space.label) {
                                    ForEach(group.items) { item in
                                        Button(item.displayName) {
                                            state.loadReferenceImage(item)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    Section("LUTs") {
                        ForEach(lutsGrouped, id: \.space) { group in
                            // If only 1 LUT, direct button. Else sub-menu.
                            if group.luts.count == 1, let lut = group.luts.first {
                                Button(lut) {
                                    state.loadReferenceLUT(fileName: lut, space: group.space)
                                }
                            } else {
                                Menu(group.space.label) {
                                    ForEach(group.luts, id: \.self) { lut in
                                        Button(lut) {
                                            state.loadReferenceLUT(fileName: lut, space: group.space)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .fixedSize()
        }
    }

    @ViewBuilder
    private var lutInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LUT Info").font(.headline)

            Group {
                if state.lutSecondary == nil {
                    Text("LUT Name: \(state.lutFileNamePrimary ?? "—")")
                } else {
                    Text("LUT 1: \(state.lutFileNamePrimary ?? "—")")
                    Text("LUT 2: \(state.lutFileNameSecondary ?? "—")")
                    Text("Global: \(state.mergedDisplayName)")
                }
                Text("Active size: \(state.uiLUT?.size.description ?? "—")")
                if let lut = state.uiLUT {
                    Text("Domain min: \(lut.domainMin.x), \(lut.domainMin.y), \(lut.domainMin.z)")
                    Text("Domain max: \(lut.domainMax.x), \(lut.domainMax.y), \(lut.domainMax.z)")
                } else {
                    Text("Domain min: —"); Text("Domain max: —")
                }
                Text("Interpolation : Tetrahedral").font(.system(size: 12)).foregroundColor(.secondary)
            }
            .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Curve").font(.headline)

            let samples = state.curveSamples()
            Chart(samples) { p in
                LineMark(x: .value("In", p.t), y: .value("Out", p.y))
                    .foregroundStyle(by: .value("Channel", p.channel))
            }
            .chartForegroundStyleScale(["R": .red, "G": .green, "B": .blue])
            .chartXScale(domain: 0...1)
            .chartYScale(domain: 0...1)
            .frame(width: 360, height: 240)

            Text("Cube").font(.headline)
            LutCubeView(lut: state.uiLUT)
                .frame(width: 360, height: 260)
        }
    }
}

// MARK: - ExportOptionsView

struct ExportOptionsView: View {
    @Binding var size: LUTExportSize
    var body: some View {
        HStack(spacing: 8) {
            Text("LUT Resolution:")
                .font(.system(size: 11, weight: .medium))
            Picker("", selection: $size) {
                Text("33").tag(LUTExportSize.s33)
                Text("65").tag(LUTExportSize.s65)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 100)
        }
        .padding(12)
    }
}

// MARK: - UTType extensions

extension UTType {
    static var cube: UTType { UTType(filenameExtension: "cube") ?? .data }
}
