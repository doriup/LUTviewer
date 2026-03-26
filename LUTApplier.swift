import AppKit
import CoreImage
import Metal

final class LUTApplier {

    // HDR-capable context (float16, extended linear sRGB)
    private let hdrContext: CIContext = {
        CIContext(options: [
            .workingFormat:     CIFormat.RGBAh,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! as AnyObject,
            .useSoftwareRenderer: false
        ])
    }()

    // SDR context (standard sRGB)
    private let sdrContext: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false])
    }()

    // MARK: - NSImage convenience (SDR fast path, backward compat)

    func apply(lut: CubeLUT, to nsImage: NSImage) -> NSImage? {
        guard let tiff   = nsImage.tiffRepresentation,
              let ciInput = CIImage(data: tiff) else { return nil }
        guard let outCI = applyToCI(lut: lut, input: ciInput) else { return nil }
        guard let outCG = sdrContext.createCGImage(outCI, from: outCI.extent) else { return nil }
        return NSImage(cgImage: outCG, size: nsImage.size)
    }

    func applyChain(luts: [CubeLUT], to nsImage: NSImage) -> NSImage? {
        guard let tiff = nsImage.tiffRepresentation,
              var ci   = CIImage(data: tiff) else { return nil }
        for lut in luts {
            guard let next = applyToCI(lut: lut, input: ci) else { return nil }
            ci = next
        }
        guard let finalCG = sdrContext.createCGImage(ci, from: ci.extent) else { return nil }
        return NSImage(cgImage: finalCG, size: nsImage.size)
    }

    // MARK: - LoadedImage path (HDR-aware)

    /// Applies a chain of LUTs to a LoadedImage, preserving HDR range.
    /// Returns an updated LoadedImage with the LUT result.
    func applyChain(luts: [CubeLUT], to loaded: LoadedImage) -> LoadedImage? {
        guard !luts.isEmpty else { return loaded }

        var ci = loaded.ciImage

        for lut in luts {
            guard let next = applyToCI(lut: lut, input: ci, hdr: loaded.isHDR) else { return nil }
            ci = next
        }

        // Render result back to CGImage (SDR thumbnail for NSImage compatibility)
        let ctx    = loaded.isHDR ? hdrContext : sdrContext
        let srgb   = CGColorSpace(name: CGColorSpace.sRGB)!
        let format: CIFormat = loaded.isHDR ? .RGBAh : .RGBA8
        guard let outCG = ctx.createCGImage(ci, from: ci.extent, format: format, colorSpace: srgb)
        else { return nil }

        return LoadedImage(
            ciImage:    ci,
            cgImage:    outCG,
            isHDR:      loaded.isHDR,
            colorSpace: loaded.colorSpace,
            width:      loaded.width,
            height:     loaded.height
        )
    }

    // MARK: - Core CIImage LUT application

    /// Applies a single CubeLUT to a CIImage.
    /// When `hdr` is true, the cube filter is driven by CIColorCubeWithColorSpace
    /// in extended linear sRGB so values > 1 are preserved.
    func applyToCI(lut: CubeLUT, input: CIImage, hdr: Bool = false) -> CIImage? {
        let cubeData = makeCubeDataRGBA(lut: lut)

        if hdr {
            // Extended linear path: use CIColorCubesMixedWithMask is not available here,
            // so we use CIColorCubeWithColorSpace in extended linear space.
            let linearCS = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
            let filter = CIFilter(name: "CIColorCubeWithColorSpace")
            filter?.setValue(lut.size,    forKey: "inputCubeDimension")
            filter?.setValue(cubeData,    forKey: "inputCubeData")
            filter?.setValue(linearCS,    forKey: "inputColorSpace")
            filter?.setValue(input,       forKey: kCIInputImageKey)
            return filter?.outputImage
        } else {
            let filter = CIFilter(name: "CIColorCubeWithColorSpace")
            filter?.setValue(lut.size,                                      forKey: "inputCubeDimension")
            filter?.setValue(cubeData,                                      forKey: "inputCubeData")
            filter?.setValue(CGColorSpace(name: CGColorSpace.sRGB),         forKey: "inputColorSpace")
            filter?.setValue(input,                                         forKey: kCIInputImageKey)
            return filter?.outputImage
        }
    }

    // MARK: - Private helpers

    private func makeCubeDataRGBA(lut: CubeLUT) -> Data {
        let s = lut.size
        var floats: [Float] = []
        floats.reserveCapacity(s * s * s * 4)

        for r in 0..<s {
            for g in 0..<s {
                for b in 0..<s {
                    let rgb = lut.table[(r * s * s) + (g * s) + b]
                    floats.append(rgb.x)
                    floats.append(rgb.y)
                    floats.append(rgb.z)
                    floats.append(1.0)
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension LUTApplier {
    func applyChainToCI(luts: [CubeLUT], input: CIImage, hdr: Bool = false) -> CIImage? {
        var ci = input
        for lut in luts {
            guard let next = applyToCI(lut: lut, input: ci, hdr: hdr) else { return nil }
            ci = next
        }
        return ci
    }
}
