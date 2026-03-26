import Foundation
import simd

struct CubeLUTWriter {

    static func write(_ lut: CubeLUT) -> String {
        var lines: [String] = []

        if let title = lut.title, !title.isEmpty {
            lines.append("TITLE \"\(title)\"")
        }

        lines.append("LUT_3D_SIZE \(lut.size)")
        lines.append("DOMAIN_MIN 0.0 0.0 0.0")
        lines.append("DOMAIN_MAX 1.0 1.0 1.0")

        for v in lut.table {
            lines.append(String(format: "%.6f %.6f %.6f", v.x, v.y, v.z))
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
