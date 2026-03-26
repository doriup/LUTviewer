//
//  lut_viewer_macosTests.swift
//  lut_viewer_macosTests
//
//  Created by Dorian on 26/01/2026.
//

import XCTest
@testable import lut_viewer_macos

    func testIdentityInterpolation() throws {
        let size = 2
        let table: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 1, 0),
            SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 1),
            SIMD3<Float>(0, 1, 1), SIMD3<Float>(1, 1, 1)
        ]
        
        let lut = CubeLUT(
            title: "Identity",
            size: size,
            domainMin: SIMD3<Float>(0, 0, 0),
            domainMax: SIMD3<Float>(1, 1, 1),
            table: table
        )
        
        let testPoints: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 1, 1),
            SIMD3<Float>(0.5, 0.5, 0.5),
            SIMD3<Float>(0.2, 0.7, 0.4)
        ]
        
        for p in testPoints {
            let resTri = lut.sample(r: p.x, g: p.y, b: p.z, type: .trilinear)
            let resTet = lut.sample(r: p.x, g: p.y, b: p.z, type: .tetrahedral)
            
            XCTAssertEqual(resTri.x, p.x, accuracy: 1e-6)
            XCTAssertEqual(resTri.y, p.y, accuracy: 1e-6)
            XCTAssertEqual(resTri.z, p.z, accuracy: 1e-6)
            
            XCTAssertEqual(resTet.x, p.x, accuracy: 1e-6)
            XCTAssertEqual(resTet.y, p.y, accuracy: 1e-6)
            XCTAssertEqual(resTet.z, p.z, accuracy: 1e-6)
        }
    }
    
    func testDomainMapping() throws {
        let size = 2
        let table: [SIMD3<Float>] = [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0), SIMD3<Float>(1, 1, 0),
            SIMD3<Float>(0, 0, 1), SIMD3<Float>(1, 0, 1),
            SIMD3<Float>(0, 1, 1), SIMD3<Float>(1, 1, 1)
        ]
        
        // LUT expects 0..1023 input
        let lut = CubeLUT(
            title: "10-bit Identity",
            size: size,
            domainMin: SIMD3<Float>(0, 0, 0),
            domainMax: SIMD3<Float>(1023, 1023, 1023),
            table: table
        )
        
        // Current app convention: sample(r,g,b) where r,g,b are 0..1 relative to viewing context
        // But internally it should map correctly.
        let out = lut.sample(r: 0.5, g: 0.5, b: 0.5, type: .trilinear)
        
        // If domain is 0..1023, and we provide 0..1 input, the sample(r,g,b) method maps it back.
        XCTAssertEqual(out.x, 0.5, accuracy: 1e-6)
    }
}
