import Foundation
import CoreImage
import simd

enum LUTExportSize: Int {
    case s33 = 33
    case s65 = 65
}

final class LUTExporter {

    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    private lazy var context: CIContext = {
        CIContext(options: [
            .useSoftwareRenderer: false,
            .workingColorSpace: sRGB,
            .outputColorSpace: sRGB
        ])
    }()

    private let applier = LUTApplier()

    func buildCubeText(luts: [CubeLUT], size: LUTExportSize, name: String) throws -> String {
        let dim = size.rawValue
        let count = dim * dim * dim

        guard !luts.isEmpty else {
            throw NSError(domain: "LUTExport", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No LUTs to export."
            ])
        }

        // 1) Identity cube en float32 (pas en 8-bit)
        let identity = makeIdentityCubeImageRGBAf(size: dim)

        // 2) Appliquer exactement la même chaîne CIColorCube que le viewer
        guard let processed = applier.applyChainToCI(luts: luts, input: identity) else {
            throw NSError(domain: "LUTExport", code: -10, userInfo: [
                NSLocalizedDescriptionKey: "Failed to apply LUT chain (CoreImage)."
            ])
        }

        // 3) Lire le résultat en float32 (.RGBAf)
        let w = dim
        let h = dim * dim
        let bytesPerPixel = 4 * MemoryLayout<Float>.size
        let rowBytes = w * bytesPerPixel

        var outFloats = [Float](repeating: 0, count: w * h * 4)

        context.render(
            processed,
            toBitmap: &outFloats,
            rowBytes: rowBytes,
            bounds: CGRect(x: 0, y: 0, width: w, height: h),
            format: .RGBAf,
            colorSpace: sRGB
        )

        // 4) Read the processed pixels and store them in the CubeLUT table.
        // The identity image was generated as Blue-fastest: x=b, y=r*dim+g.
        // Our internal table is Blue-fastest: index = r*dim*dim + g*dim + b.
        var table: [SIMD3<Float>] = Array(repeating: SIMD3<Float>(0, 0, 0), count: count)

        for r in 0..<dim {
            for g in 0..<dim {
                for b in 0..<dim {
                    let x = b
                    let y = r * dim + g
                    
                    // CoreImage has Y=0 at the bottom.
                    let yIndex = (h - 1) - y
                    let pixIndex = (yIndex * w + x) * 4
                    
                    let rf = outFloats[pixIndex]
                    let gf = outFloats[pixIndex + 1]
                    let bf = outFloats[pixIndex + 2]
                    
                    let lutIndex = (r * dim * dim) + (g * dim) + b
                    table[lutIndex] = SIMD3<Float>(rf, gf, bf)
                }
            }
        }

        let out = CubeLUT(
            title: name,
            size: dim,
            domainMin: SIMD3<Float>(0, 0, 0),
            domainMax: SIMD3<Float>(1, 1, 1),
            table: table
        )

        return CubeLUTWriter.write(out)
    }

    // Image 2D qui représente un cube 3D identity en float32 RGBA (RGBAf)
    //
    // Convention (celle qu’on utilise ici pour générer l’image) :
    // x = r
    // y = g*size + b
    private func makeIdentityCubeImageRGBAf(size: Int) -> CIImage {
        let w = size
        let h = size * size

        let denom = Float(max(size - 1, 1))
        var floats = [Float](repeating: 0, count: w * h * 4)

        for r in 0..<size {
            let rf = Float(r) / denom
            for g in 0..<size {
                let gf = Float(g) / denom
                for b in 0..<size {
                    let bf = Float(b) / denom

                    // Convention Blue-fastest: x=b, y=r*size + g
                    let x = b
                    let y = r * size + g

                    let idx = (y * w + x) * 4
                    floats[idx]     = rf
                    floats[idx + 1] = gf
                    floats[idx + 2] = bf
                    floats[idx + 3] = 1.0
                }
            }
        }

        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }

        return CIImage(
            bitmapData: data,
            bytesPerRow: w * 4 * MemoryLayout<Float>.size,
            size: CGSize(width: w, height: h),
            format: .RGBAf,
            colorSpace: sRGB
        )
    }
}

