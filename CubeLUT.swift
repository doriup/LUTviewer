import Foundation
import simd

struct CubeLUT {
    enum InterpolationType {
        case trilinear
        case tetrahedral
    }

    var title: String?
    var size: Int
    var domainMin: SIMD3<Float>
    var domainMax: SIMD3<Float>
    var table: [SIMD3<Float>]
}

extension CubeLUT {
    static func composed(_ lutA: CubeLUT, _ lutB: CubeLUT, outputSize: Int? = nil, interpolation: InterpolationType = .trilinear) -> CubeLUT {
        let chosen: Int
        if let outputSize {
            chosen = max(2, outputSize)
        } else {
            chosen = min(max(lutA.size, lutB.size), 65)
        }

        let s = chosen
        let count = s * s * s
        var outTable: [SIMD3<Float>] = Array(repeating: SIMD3<Float>(0, 0, 0), count: count)

        @inline(__always)
        func clamp01(_ v: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(
                min(max(v.x, 0), 1),
                min(max(v.y, 0), 1),
                min(max(v.z, 0), 1)
            )
        }

        let denom = Float(max(s - 1, 1))
        var idx = 0

        for r in 0..<s {
            let rf = Float(r) / denom
            for g in 0..<s {
                let gf = Float(g) / denom
                for b in 0..<s {
                    let bf = Float(b) / denom

                    let aOut = lutA.sample(r: rf, g: gf, b: bf, type: interpolation)
                    let aClamped = clamp01(aOut)
                    let bOut = lutB.sample(r: aClamped.x, g: aClamped.y, b: aClamped.z, type: interpolation)

                    outTable[idx] = bOut
                    idx += 1
                }
            }
        }

        let aName = lutA.title?.isEmpty == false ? lutA.title! : "LUT 1"
        let bName = lutB.title?.isEmpty == false ? lutB.title! : "LUT 2"

        return CubeLUT(
            title: "\(aName) + \(bName)",
            size: s,
            domainMin: SIMD3<Float>(0, 0, 0),
            domainMax: SIMD3<Float>(1, 1, 1),
            table: outTable
        )
    }
}

enum CubeParseError: Error, LocalizedError {
    case missingSize
    case notEnoughData(expected: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .missingSize:
            return "Invalid .cube file: LUT_3D_SIZE not found."
        case .notEnoughData(let expected, let got):
            return "Invalid .cube file: not enough data (\(got) < \(expected))."
        }
    }
}

final class CubeParser {

    static func load(from url: URL) throws -> CubeLUT {
        let text = try String(contentsOf: url, encoding: .utf8)

        var title: String?
        var size: Int?
        var domainMin = SIMD3<Float>(0, 0, 0)
        var domainMax = SIMD3<Float>(1, 1, 1)

        var rawData: [SIMD3<Float>] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if let hash = line.firstIndex(of: "#") {
                line = String(line[..<hash]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.isEmpty { continue }

            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.isEmpty { continue }

            let key = parts[0].uppercased()

            switch key {
            case "TITLE":
                let rest = line.dropFirst("TITLE".count)
                title = rest
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            case "LUT_3D_SIZE":
                if parts.count >= 2 { size = Int(parts[1]) }

            case "DOMAIN_MIN":
                if parts.count >= 4 {
                    domainMin = SIMD3<Float>(
                        Float(parts[1]) ?? 0,
                        Float(parts[2]) ?? 0,
                        Float(parts[3]) ?? 0
                    )
                }

            case "DOMAIN_MAX":
                if parts.count >= 4 {
                    domainMax = SIMD3<Float>(
                        Float(parts[1]) ?? 1,
                        Float(parts[2]) ?? 1,
                        Float(parts[3]) ?? 1
                    )
                }

            default:
                if parts.count == 3,
                   let r = Float(parts[0]),
                   let g = Float(parts[1]),
                   let b = Float(parts[2]) {
                    rawData.append(SIMD3<Float>(r, g, b))
                }
            }
        }

        guard let s = size else { throw CubeParseError.missingSize }

        let expected = s * s * s
        guard rawData.count >= expected else {
            throw CubeParseError.notEnoughData(expected: expected, got: rawData.count)
        }

        rawData = Array(rawData.prefix(expected))

        var table = Array(repeating: SIMD3<Float>(0, 0, 0), count: expected)

        var i = 0
        for r in 0..<s {
            for g in 0..<s {
                for b in 0..<s {
                    table[(r * s * s) + (g * s) + b] = rawData[i]
                    i += 1
                }
            }
        }

        return CubeLUT(
            title: title,
            size: s,
            domainMin: domainMin,
            domainMax: domainMax,
            table: table
        )
    }
}

extension CubeLUT {

    @inline(__always)
    private func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        a + (b - a) * t
    }

    func sample(r: Float, g: Float, b: Float, type: InterpolationType = .trilinear) -> SIMD3<Float> {
        switch type {
        case .trilinear:
            return sampleTrilinear(r: r, g: g, b: b)
        case .tetrahedral:
            return sampleTetrahedral(r: r, g: g, b: b)
        }
    }

    func sampleTrilinear(r: Float, g: Float, b: Float) -> SIMD3<Float> {
        let s = size
        let maxIndex = Float(s - 1)

        // Map 0..1 input to domainMin..domainMax
        let r_in = domainMin.x + r * (domainMax.x - domainMin.x)
        let g_in = domainMin.y + g * (domainMax.y - domainMin.y)
        let b_in = domainMin.z + b * (domainMax.z - domainMin.z)

        // Normalize back to 0..1 relative to domain, then scale to 0..maxIndex
        let rf = min(max((r_in - domainMin.x) / (domainMax.x - domainMin.x), 0), 1) * maxIndex
        let gf = min(max((g_in - domainMin.y) / (domainMax.y - domainMin.y), 0), 1) * maxIndex
        let bf = min(max((b_in - domainMin.z) / (domainMax.z - domainMin.z), 0), 1) * maxIndex

        let r0 = Int(floor(rf))
        let g0 = Int(floor(gf))
        let b0 = Int(floor(bf))

        let r1 = min(r0 + 1, s - 1)
        let g1 = min(g0 + 1, s - 1)
        let b1 = min(b0 + 1, s - 1)

        let dr = rf - Float(r0)
        let dg = gf - Float(g0)
        let db = bf - Float(b0)

        @inline(__always)
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            table[(r * s * s) + (g * s) + b]
        }

        let c000 = at(r0, g0, b0)
        let c100 = at(r1, g0, b0)
        let c010 = at(r0, g1, b0)
        let c110 = at(r1, g1, b0)
        let c001 = at(r0, g0, b1)
        let c101 = at(r1, g0, b1)
        let c011 = at(r0, g1, b1)
        let c111 = at(r1, g1, b1)

        let c00 = lerp(c000, c100, dr)
        let c10 = lerp(c010, c110, dr)
        let c01 = lerp(c001, c101, dr)
        let c11 = lerp(c011, c111, dr)

        let c0 = lerp(c00, c10, dg)
        let c1 = lerp(c01, c11, dg)

        return lerp(c0, c1, db)
    }

    func sampleTetrahedral(r: Float, g: Float, b: Float) -> SIMD3<Float> {
        let s = size
        let maxIndex = Float(s - 1)

        let rf = min(max(r, 0), 1) * maxIndex
        let gf = min(max(g, 0), 1) * maxIndex
        let bf = min(max(b, 0), 1) * maxIndex

        let r0 = Int(floor(rf))
        let g0 = Int(floor(gf))
        let b0 = Int(floor(bf))

        let r1 = min(r0 + 1, s - 1)
        let g1 = min(g0 + 1, s - 1)
        let b1 = min(b0 + 1, s - 1)

        let dr = rf - Float(r0)
        let dg = gf - Float(g0)
        let db = bf - Float(b0)

        @inline(__always)
        func at(_ r: Int, _ g: Int, _ b: Int) -> SIMD3<Float> {
            table[(r * s * s) + (g * s) + b]
        }

        let c000 = at(r0, g0, b0)
        let c111 = at(r1, g1, b1)

        if dr > dg {
            if dg > db {
                let c100 = at(r1, g0, b0)
                let c110 = at(r1, g1, b0)
                return c000 * (1.0 - dr) + c100 * (dr - dg) + c110 * (dg - db) + c111 * db
            } else if dr > db {
                let c100 = at(r1, g0, b0)
                let c101 = at(r1, g0, b1)
                return c000 * (1.0 - dr) + c100 * (dr - db) + c101 * (db - dg) + c111 * dg
            } else {
                let c001 = at(r0, g0, b1)
                let c101 = at(r1, g0, b1)
                return c000 * (1.0 - db) + c001 * (db - dr) + c101 * (dr - dg) + c111 * dg
            }
        } else {
            if db > dg {
                let c001 = at(r0, g0, b1)
                let c011 = at(r0, g1, b1)
                return c000 * (1.0 - db) + c001 * (db - dg) + c011 * (dg - dr) + c111 * dr
            } else if db > dr {
                let c010 = at(r0, g1, b0)
                let c011 = at(r0, g1, b1)
                return c000 * (1.0 - dg) + c010 * (dg - db) + c011 * (db - dr) + c111 * dr
            } else {
                let c010 = at(r0, g1, b0)
                let c110 = at(r1, g1, b0)
                return c000 * (1.0 - dg) + c010 * (dg - dr) + c110 * (dr - db) + c111 * db
            }
        }
    }
}
