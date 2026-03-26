import SwiftUI
import AppKit
import CoreImage
import Metal
import QuartzCore

// MARK: - HDRImageView
//
// An NSViewRepresentable that renders a CIImage in EDR (Extended Dynamic Range) mode
// when `hdrEnabled` is true and the display supports it.
// Falls back to SDR NSImageView otherwise.

struct HDRImageView: NSViewRepresentable {

    let image: LoadedImage?
    let hdrEnabled: Bool

    func makeNSView(context: Context) -> HDRHostView {
        let v = HDRHostView()
        return v
    }

    func updateNSView(_ nsView: HDRHostView, context: Context) {
        nsView.setImage(image, hdrEnabled: hdrEnabled)
    }
}

// MARK: - HDRHostView

final class HDRHostView: NSView {

    // Metal / EDR layer (lazy to avoid creating unless needed)
    private var metalLayer: CAMetalLayer?
    private var ciContext: CIContext?
    private var commandQueue: MTLCommandQueue?

    // SDR fallback
    private let imageView: NSImageView = {
        let iv = NSImageView()
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private var currentImage: LoadedImage?
    private var currentHDR:   Bool = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true   // prevent CAMetalLayer from escaping view bounds
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Public

    func setImage(_ loaded: LoadedImage?, hdrEnabled: Bool) {
        currentImage = loaded
        currentHDR   = hdrEnabled && (loaded?.isHDR ?? false)
        refresh()
    }

    override func layout() {
        super.layout()
        metalLayer?.frame = bounds
        metalLayer?.drawableSize = CGSize(
            width:  bounds.width  * (window?.backingScaleFactor ?? 1),
            height: bounds.height * (window?.backingScaleFactor ?? 1)
        )
        if currentHDR { renderHDR() }
    }

    // MARK: - Routing

    private func refresh() {
        if currentHDR {
            setupMetalLayerIfNeeded()
            imageView.isHidden = true
            renderHDR()
        } else {
            metalLayer?.isHidden = true
            imageView.isHidden   = false
            renderSDR()
        }
    }

    // MARK: - SDR path

    private func renderSDR() {
        guard let loaded = currentImage else {
            imageView.image = nil
            return
        }
        imageView.image = NSImage(cgImage: loaded.cgImage,
                                  size: NSSize(width: loaded.width, height: loaded.height))
    }

    // MARK: - HDR / EDR path

    private func setupMetalLayerIfNeeded() {
        if metalLayer != nil { return }

        guard let device = MTLCreateSystemDefaultDevice() else { return }

        let ml = CAMetalLayer()
        ml.device                             = device
        ml.pixelFormat                        = .rgba16Float
        ml.wantsExtendedDynamicRangeContent   = true
        ml.colorspace                         = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        ml.framebufferOnly                    = false
        ml.frame                              = bounds
        ml.contentsScale                      = window?.backingScaleFactor ?? 2.0
        layer?.addSublayer(ml)
        metalLayer = ml

        commandQueue = device.makeCommandQueue()
        ciContext = CIContext(mtlDevice: device, options: [
            .workingFormat:     CIFormat.RGBAh,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)! as AnyObject,
            .outputPremultiplied: false
        ])

        ml.isHidden = false
    }

    private func renderHDR() {
        guard
            let loaded  = currentImage,
            let ml      = metalLayer,
            let ctx     = ciContext,
            let queue   = commandQueue,
            let drawable = ml.nextDrawable()
        else { return }

        let drawableSize = ml.drawableSize
        let scaleX = drawableSize.width  / CGFloat(loaded.width)
        let scaleY = drawableSize.height / CGFloat(loaded.height)
        let scale  = min(scaleX, scaleY)           // aspect-fit
        let scaledW = CGFloat(loaded.width)  * scale
        let scaledH = CGFloat(loaded.height) * scale
        let tx = (drawableSize.width  - scaledW) / 2
        let ty = (drawableSize.height - scaledH) / 2

        // Scale + flip (CIImage origin is bottom-left, Metal drawable is top-left)
        var transform = CGAffineTransform(scaleX: scale, y: -scale)
        transform = transform.translatedBy(x: 0, y: -CGFloat(loaded.height))
        transform = transform.translatedBy(x: tx / scale, y: -ty / scale)

        let finalCI = loaded.ciImage.transformed(by: transform)

        guard let cb = queue.makeCommandBuffer() else { return }

        ctx.render(
            finalCI,
            to:          drawable.texture,
            commandBuffer: cb,
            bounds:      CGRect(origin: .zero, size: drawableSize),
            colorSpace:  CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        )
        cb.present(drawable)
        cb.commit()
    }
}
