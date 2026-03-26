import Foundation
import CoreGraphics
import AppKit
import Accelerate

final class DPXReader {
    
    enum DPXError: Error, LocalizedError {
        case invalidMagic
        case unsupportedFormat(String)
        case smallFile
        
        var errorDescription: String? {
            switch self {
            case .invalidMagic:           return "Invalid DPX file (Magic number mismatch)."
            case .unsupportedFormat(let msg): return "Unsupported DPX format: \(msg)"
            case .smallFile:              return "File is too small to be a valid DPX."
            }
        }
    }
    
    // Pre-computed lookup table: 10-bit value → 8-bit value
    private static let lut10to8: [UInt8] = {
        (0..<1024).map { UInt8(($0 * 255) / 1023) }
    }()

    func load(url: URL) throws -> CGImage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 1664 else { throw DPXError.smallFile }
        
        // 1) Parse Magic (SDPX or XPDS)
        let magicData = data.prefix(4)
        let isBigEndian: Bool
        if magicData == Data([0x53, 0x44, 0x50, 0x58]) {      // "SDPX"
            isBigEndian = true
        } else if magicData == Data([0x58, 0x50, 0x44, 0x53]) { // "XPDS"
            isBigEndian = false
        } else {
            throw DPXError.invalidMagic
        }
        
        // 2) Offset to image data (offset 4)
        let offset = Int(readUInt32(data: data, at: 4, bigEndian: isBigEndian))
        guard offset >= 1664, offset < data.count else {
            throw DPXError.unsupportedFormat("Invalid data offset: \(offset)")
        }
        
        // 3) Generic Image Header starts at 768
        let width  = Int(readUInt32(data: data, at: 772, bigEndian: isBigEndian))
        let height = Int(readUInt32(data: data, at: 776, bigEndian: isBigEndian))
        
        // Descriptor (offset 800): 50 = RGB, 51 = RGBA
        let descriptor = data[800]
        guard descriptor == 50 || descriptor == 51 else {
            throw DPXError.unsupportedFormat("Unsupported descriptor \(descriptor)")
        }
        
        // Bit depth (offset 803)
        let bitDepth = data[803]
        guard bitDepth == 10 else {
            throw DPXError.unsupportedFormat("Only 10-bit supported, got \(bitDepth)")
        }
        
        // Packing (offset 804): 0 = Packed (Method A)
        let packing = data[804]
        guard packing == 0 else {
            throw DPXError.unsupportedFormat("Only Method A packing supported, got \(packing)")
        }
        
        guard width > 0, height > 0, width < 16384, height < 16384 else {
            throw DPXError.unsupportedFormat("Invalid dimensions: \(width)x\(height)")
        }
        
        // 4) Unpack pixels
        let elementSize = width * height * 4
        if data.count < offset + elementSize {
            throw DPXError.unsupportedFormat("Truncated file. Need \(offset + elementSize) bytes.")
        }
        
        return try unpack10BitMethodA(
            data: data,
            pixelDataOffset: offset,
            width: width,
            height: height,
            bigEndian: isBigEndian
        )
    }
    
    // MARK: - Fast 10-bit Method A decoder
    
    private func unpack10BitMethodA(
        data: Data,
        pixelDataOffset: Int,
        width: Int,
        height: Int,
        bigEndian: Bool
    ) throws -> CGImage {

        let pixelCount  = width * height
        let bytesPerRow = width * 4          // output: RGBA8

        // Allocate the CGContext output buffer directly (avoids a copy)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.noneSkipLast.rawValue  // RGBX – fastest path

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ), let destBase = ctx.data else {
            throw DPXError.unsupportedFormat("Failed to create CGContext.")
        }

        let lut = DPXReader.lut10to8
        let dest = destBase.assumingMemoryBound(to: UInt8.self)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let src = raw.baseAddress else { return }
            // Pointer to the first pixel word in the source
            let words = (src + pixelDataOffset).assumingMemoryBound(to: UInt32.self)

            if bigEndian {
                // Most DPX files are big-endian; compiler can vectorise this loop easily
                for i in 0..<pixelCount {
                    let word = CFSwapInt32BigToHost(words[i])
                    let j    = i &* 4
                    dest[j]     = lut[Int((word >> 22) & 0x3FF)]  // R
                    dest[j + 1] = lut[Int((word >> 12) & 0x3FF)]  // G
                    dest[j + 2] = lut[Int((word >>  2) & 0x3FF)]  // B
                    dest[j + 3] = 255                              // X/A
                }
            } else {
                for i in 0..<pixelCount {
                    let word = CFSwapInt32LittleToHost(words[i])
                    let j    = i &* 4
                    dest[j]     = lut[Int((word >> 22) & 0x3FF)]
                    dest[j + 1] = lut[Int((word >> 12) & 0x3FF)]
                    dest[j + 2] = lut[Int((word >>  2) & 0x3FF)]
                    dest[j + 3] = 255
                }
            }
        }

        guard let cgImage = ctx.makeImage() else {
            throw DPXError.unsupportedFormat("Failed to extract image from context.")
        }
        return cgImage
    }
    
    // MARK: - Helpers
    
    private func readUInt32(data: Data, at offset: Int, bigEndian: Bool) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        if bigEndian {
            return (UInt32(data[offset])   << 24) |
                   (UInt32(data[offset+1]) << 16) |
                   (UInt32(data[offset+2]) <<  8) |
                    UInt32(data[offset+3])
        } else {
            return (UInt32(data[offset+3]) << 24) |
                   (UInt32(data[offset+2]) << 16) |
                   (UInt32(data[offset+1]) <<  8) |
                    UInt32(data[offset+0])
        }
    }
}
