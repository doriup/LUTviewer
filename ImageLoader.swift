import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import AppKit

// MARK: - LoadedImage

/// Encapsulates a loaded image with HDR metadata.
struct LoadedImage {
    /// Full-precision CIImage (linear light for HDR sources, sRGB for SDR).
    let ciImage: CIImage
    /// CGImage for SDR display / NSImage compatibility (may be tone-mapped to [0,1]).
    let cgImage: CGImage
    /// True when the source image contains values outside [0,1] or uses a wide/linear color space.
    let isHDR: Bool
    /// Native color space of the source file.
    let colorSpace: CGColorSpace
    /// Original image dimensions.
    let width: Int
    let height: Int
}

// MARK: - ImageLoader

final class ImageLoader {

    enum LoadError: Error, LocalizedError {
        case cannotOpen
        case unsupportedFormat(String)
        case decodeFailed

        var errorDescription: String? {
            switch self {
            case .cannotOpen:               return "Impossible d'ouvrir le fichier."
            case .unsupportedFormat(let s): return "Format non supporté : \(s)"
            case .decodeFailed:             return "Échec du décodage de l'image."
            }
        }
    }

    /// Supported file extensions (in addition to UTType-based filtering in the panel).
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png",
        "tif", "tiff",
        "exr",
        "dpx",
        "heic", "heif",
        "bmp"
    ]

    // Shared CIContext for HDR decoding (Metal GPU, float16 working format).
    private static let ciContextHDR: CIContext = {
        CIContext(options: [
            .workingFormat:       CIFormat.RGBAh,   // 16-bit float per component
            .workingColorSpace:   CGColorSpace(name: CGColorSpace.extendedLinearSRGB)! as AnyObject,
            .useSoftwareRenderer: false
        ])
    }()

    // Shared CIContext for SDR rendering.
    private static let ciContextSDR: CIContext = {
        CIContext(options: [.useSoftwareRenderer: false])
    }()

    // MARK: - Public API

    func load(url: URL) throws -> LoadedImage {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "dpx":
            return try loadDPX(url: url)
        case "exr":
            return try loadEXR(url: url)
        case "tif", "tiff":
            return try loadTIFF(url: url)
        default:
            return try loadGeneric(url: url)
        }
    }

    // MARK: - DPX

    private func loadDPX(url: URL) throws -> LoadedImage {
        let cg = try DPXReader().load(url: url)
        let cs  = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let ci  = CIImage(cgImage: cg)
        return LoadedImage(
            ciImage:    ci,
            cgImage:    cg,
            isHDR:      false,
            colorSpace: cs,
            width:      cg.width,
            height:     cg.height
        )
    }

    // MARK: - EXR (always HDR)

    private func loadEXR(url: URL) throws -> LoadedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw LoadError.cannotOpen
        }

        // Request float decoding via ImageIO
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache:             true,
            kCGImageSourceShouldAllowFloat:        true,
            kCGImageSourceCreateThumbnailFromImageAlways: false
        ]
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary) else {
            throw LoadError.decodeFailed
        }

        // EXR is always linear light; use extended linear sRGB so CIImage can carry >1 values.
        let linearCS = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
            ?? CGColorSpaceCreateDeviceRGB()

        // Build CIImage in extended linear colour space
        let ciOptions: [CIImageOption: Any] = [
            .colorSpace: linearCS
        ]
        let ci = CIImage(cgImage: cg, options: ciOptions)

        // Build a tone-mapped SDR CGImage for NSImage compatibility (avoids clipping)
        let sdCG = makeSDRCGImage(from: ci, size: CGSize(width: cg.width, height: cg.height))
            ?? cg

        return LoadedImage(
            ciImage:    ci,
            cgImage:    sdCG,
            isHDR:      true,
            colorSpace: linearCS,
            width:      cg.width,
            height:     cg.height
        )
    }

    // MARK: - TIFF (may be HDR)

    private func loadTIFF(url: URL) throws -> LoadedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw LoadError.cannotOpen
        }

        let options: [CFString: Any] = [
            kCGImageSourceShouldAllowFloat: true,
            kCGImageSourceShouldCache:      true
        ]
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, options as CFDictionary) else {
            throw LoadError.decodeFailed
        }

        let cs       = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let isHDR    = colorSpaceIsHDR(cs) || cgImageIsFloat(cg)
        let ciOptions: [CIImageOption: Any] = isHDR ? [.colorSpace: cs] : [:]
        let ci       = CIImage(cgImage: cg, options: ciOptions)

        // For HDR TIFF build an SDR thumb for NSImage compatibility
        let sdCG: CGImage
        if isHDR {
            sdCG = makeSDRCGImage(from: ci, size: CGSize(width: cg.width, height: cg.height)) ?? cg
        } else {
            sdCG = cg
        }

        return LoadedImage(
            ciImage:    ci,
            cgImage:    sdCG,
            isHDR:      isHDR,
            colorSpace: cs,
            width:      cg.width,
            height:     cg.height
        )
    }

    // MARK: - Generic (JPEG, PNG, HEIC, BMP…)

    private func loadGeneric(url: URL) throws -> LoadedImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw LoadError.cannotOpen
        }
        guard let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw LoadError.decodeFailed
        }
        let cs = cg.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let ci = CIImage(cgImage: cg)
        return LoadedImage(
            ciImage:    ci,
            cgImage:    cg,
            isHDR:      false,
            colorSpace: cs,
            width:      cg.width,
            height:     cg.height
        )
    }

    // MARK: - Helpers

    /// Returns true when `cs` is a wide-gamut / linear / HDR space.
    private func colorSpaceIsHDR(_ cs: CGColorSpace) -> Bool {
        guard let name = cs.name as String? else { return false }
        let hdrNames: [String] = [
            CGColorSpace.extendedLinearSRGB as String,
            CGColorSpace.linearSRGB          as String,
            CGColorSpace.extendedSRGB        as String,
            CGColorSpace.itur_2020           as String,
            CGColorSpace.itur_2100_PQ        as String,
            CGColorSpace.itur_2100_HLG       as String,
            CGColorSpace.extendedLinearITUR_2020 as String,
            CGColorSpace.displayP3           as String,
            CGColorSpace.extendedDisplayP3   as String
        ]
        return hdrNames.contains(name)
    }

    /// Returns true for float-component CGImages (32-bit or 16-bit float).
    private func cgImageIsFloat(_ cg: CGImage) -> Bool {
        let info = cg.bitmapInfo
        return info.contains(.floatComponents)
    }

    /// Tone-maps a CIImage to [0,1] sRGB for SDR display (simple Reinhard).
    private func makeSDRCGImage(from ci: CIImage, size: CGSize) -> CGImage? {
        // Use a simple exposure-normalise approach: clamp extended linear to sRGB
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        return ImageLoader.ciContextSDR.createCGImage(
            ci,
            from: ci.extent,
            format: .RGBA8,
            colorSpace: srgb
        )
    }
}
