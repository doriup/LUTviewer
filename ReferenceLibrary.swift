import Foundation
import AppKit

// MARK: - ReferenceSpace

enum ReferenceSpace: String, CaseIterable {
    case sony    = "sony"
    case arri    = "arri"
    case red     = "red"
    case cineon  = "cineon"

    var label: String {
        switch self {
        case .sony:   return "Sony S-Log3 / S-Gamut3.Cine"
        case .arri:   return "ARRI LogC3 / ARRI Wide Gamut"
        case .red:    return "RED Log3G10 / REDWideGamutRGB"
        case .cineon: return "Cineon Film Log"
        }
    }
}

// MARK: - ReferenceItem

struct ReferenceItem: Identifiable, Hashable {
    let id                    = UUID()
    /// Human-readable name shown in the menu (e.g. "Portrait 01")
    let displayName:           String
    /// Enum value of the colour space family
    let space:                 ReferenceSpace
    /// Human-readable colour space label
    var colorSpaceLabel:       String { space.label }
    /// File name of the TIFF (with extension)
    let imageFileName:         String
    /// Default display LUT file name (with extension) for this space
    let defaultLUTFileName:    String

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (l: ReferenceItem, r: ReferenceItem) -> Bool { l.id == r.id }
}

// MARK: - ReferenceLibrary

final class ReferenceLibrary {

    static let shared = ReferenceLibrary()

    /// All available reference items, grouped by space.
    /// Loaded lazily once at first access.
    private(set) lazy var items: [ReferenceItem] = { buildItems() }()

    /// All items grouped by space (preserves ReferenceSpace.allCases order).
    func itemsBySpace() -> [(space: ReferenceSpace, items: [ReferenceItem])] {
        ReferenceSpace.allCases.compactMap { space in
            let matching = items.filter { $0.space == space }
            return matching.isEmpty ? nil : (space, matching)
        }
    }

    // MARK: - URL resolution

    /// Returns the bundle URL for a given TIFF file.
    func imageURL(for item: ReferenceItem) -> URL? {
        // Try to find the directory robustly
        guard let imagesDir = Bundle.main.url(forResource: "ReferenceImages", withExtension: nil) else { return nil }
        
        // 1. Try nested: ReferenceImages/sony/sony.tif
        let nested = imagesDir.appendingPathComponent(item.space.rawValue).appendingPathComponent(item.imageFileName)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        
        // 2. Try flat: ReferenceImages/sony.tif
        let flat = imagesDir.appendingPathComponent(item.imageFileName)
        if FileManager.default.fileExists(atPath: flat.path) { return flat }
        
        return nil
    }

    /// Returns the bundle URL for a given CUBE file.
    func lutURL(for item: ReferenceItem, lutFileName: String? = nil) -> URL? {
        guard let lutsDir = Bundle.main.url(forResource: "ReferenceLUTs", withExtension: nil) else { return nil }
        let name = lutFileName ?? item.defaultLUTFileName
        
        // 1. Try nested
        let nested = lutsDir.appendingPathComponent(item.space.rawValue).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: nested.path) { return nested }
        
        // 2. Try flat
        let flat = lutsDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: flat.path) { return flat }
        
        return nil
    }

    /// All CUBE files available for a given space.
    func availableLUTs(for space: ReferenceSpace) -> [String] {
        guard let lutsDir = Bundle.main.url(forResource: "ReferenceLUTs", withExtension: nil) else { return [] }
        
        var allCubes: [String] = []
        
        // Scan nested folder if it exists
        let nestedDir = lutsDir.appendingPathComponent(space.rawValue)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: nestedDir.path) {
            allCubes.append(contentsOf: files.filter { $0.lowercased().hasSuffix(".cube") })
        }
        
        // Scan flat root
        if let files = try? FileManager.default.contentsOfDirectory(atPath: lutsDir.path) {
            let flatFiles = files.filter { $0.lowercased().hasSuffix(".cube") && matches(filename: $0, for: space) }
            allCubes.append(contentsOf: flatFiles)
        }
        
        return Array(Set(allCubes)).sorted()
    }

    /// Returns all available LUT names grouped by space.
    func allAvailableLUTsBySpace() -> [(space: ReferenceSpace, luts: [String])] {
        ReferenceSpace.allCases.compactMap { space in
            let luts = availableLUTs(for: space)
            return luts.isEmpty ? nil : (space, luts)
        }
    }

    private func matches(filename: String, for space: ReferenceSpace) -> Bool {
        let low = filename.lowercased()
        switch space {
        case .sony:
            return low.starts(with: "sony") || low.contains("slog3") || low.contains("s-gamut")
        case .arri:
            return low.starts(with: "arri") || low.contains("awg3") || low.contains("logc3")
        case .red:
            return low.starts(with: "red") || low.contains("rwg") || low.contains("log3g10")
        case .cineon:
            return low.starts(with: "cineon")
        }
    }

    // MARK: - Dynamic scan

    private func buildItems() -> [ReferenceItem] {
        var result: [ReferenceItem] = []
        print("ReferenceLibrary: Scanning bundle...")

        for space in ReferenceSpace.allCases {
            let tiffs  = tiffFiles(for: space)
            let cubes  = availableLUTs(for: space)
            let defLUT = cubes.first(where: { $0.lowercased().contains("709") }) ?? cubes.first ?? ""

            if !tiffs.isEmpty {
                print("ReferenceLibrary: Found \(tiffs.count) images for space \(space.rawValue)")
            }

            for tiff in tiffs {
                let displayName = tiff
                    .replacingOccurrences(of: ".tiff", with: "", options: .caseInsensitive)
                    .replacingOccurrences(of: ".tif",  with: "", options: .caseInsensitive)

                result.append(ReferenceItem(
                    displayName:        displayName,
                    space:              space,
                    imageFileName:      tiff,
                    defaultLUTFileName: defLUT
                ))
            }
        }
        
        if result.isEmpty {
            print("ReferenceLibrary WARNING: No reference items found! Check Bundle structure.")
        } else {
            print("ReferenceLibrary: Loaded \(result.count) items.")
        }
        return result
    }

    private func tiffFiles(for space: ReferenceSpace) -> [String] {
        guard let imagesDir = Bundle.main.url(forResource: "ReferenceImages", withExtension: nil) else { return [] }
        
        var allTiffs: [String] = []
        
        // 1. Scan nested folder
        let nestedDir = imagesDir.appendingPathComponent(space.rawValue)
        if let files = try? FileManager.default.contentsOfDirectory(atPath: nestedDir.path) {
            allTiffs.append(contentsOf: files.filter { $0.lowercased().hasSuffix(".tiff") || $0.lowercased().hasSuffix(".tif") })
        }
        
        // 2. Scan flat root for files matching the space
        if let files = try? FileManager.default.contentsOfDirectory(atPath: imagesDir.path) {
            let flatFiles = files.filter { 
                let low = $0.lowercased()
                return (low.hasSuffix(".tiff") || low.hasSuffix(".tif")) && matches(filename: $0, for: space)
            }
            allTiffs.append(contentsOf: flatFiles)
        }
        
        return Array(Set(allTiffs)).sorted()
    }
}
