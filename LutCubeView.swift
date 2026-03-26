import SwiftUI
import SceneKit
import simd

struct LutCubeView: NSViewRepresentable {

    var lut: CubeLUT?

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = SCNScene()
        view.allowsCameraControl = true
        view.backgroundColor = .black
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X

        view.scene?.rootNode.addChildNode(makeCameraNode())
        view.scene?.rootNode.addChildNode(makeLightNode())

        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        guard let scene = nsView.scene else { return }

        let keepNames: Set<String> = ["camera", "light"]
        for node in scene.rootNode.childNodes {
            if let name = node.name, keepNames.contains(name) { continue }
            node.removeFromParentNode()
        }

        // Thin white outline cube
        let outline = makeWireframeCubeNode(
            color: .white,
            thickness: 0.002,
            name: "outlineCube"
        )
        scene.rootNode.addChildNode(outline)

        // RGB axes (R=X, G=Y, B=Z)
        let axes = makeAxesNode(axisLength: 0.75, thickness: 0.004, name: "axes")
        scene.rootNode.addChildNode(axes)

        // LUT point cloud inside
        let transform: (SIMD3<Float>) -> SIMD3<Float> = { p in
            if let lut = self.lut {
                let out = lut.sampleTrilinear(r: p.x, g: p.y, b: p.z)
                return SIMD3<Float>(out.x, out.y, out.z)
            } else {
                return p
            }
        }

        let points = makePointCloudNode(
            samplesPerAxis: 33,          // 17/25/33/49... (33 ≈ 35k points)
            transform: transform,
            name: "lutPoints"
        )
        scene.rootNode.addChildNode(points)
    }

    // MARK: - Camera / Light

    private func makeCameraNode() -> SCNNode {
        let camera = SCNCamera()
        camera.zNear = 0.01
        camera.zFar = 100
        camera.fieldOfView = 45

        let node = SCNNode()
        node.name = "camera"
        node.camera = camera

        // 3/4 close (adjust if needed)
        node.position = SCNVector3(1.3, 1.0, 1.9)
        node.look(at: SCNVector3(0, 0, 0))

        return node
    }

    private func makeLightNode() -> SCNNode {
        let light = SCNLight()
        light.type = .omni
        light.intensity = 450

        let node = SCNNode()
        node.name = "light"
        node.light = light
        node.position = SCNVector3(2.5, 2.5, 3.5)
        return node
    }

    // MARK: - Outline cube (thin)

    private func makeWireframeCubeNode(color: NSColor, thickness: CGFloat, name: String) -> SCNNode {
        let c000 = SIMD3<Float>(0,0,0)
        let c100 = SIMD3<Float>(1,0,0)
        let c010 = SIMD3<Float>(0,1,0)
        let c110 = SIMD3<Float>(1,1,0)
        let c001 = SIMD3<Float>(0,0,1)
        let c101 = SIMD3<Float>(1,0,1)
        let c011 = SIMD3<Float>(0,1,1)
        let c111 = SIMD3<Float>(1,1,1)

        let edges: [(SIMD3<Float>, SIMD3<Float>)] = [
            (c000, c100), (c000, c010), (c000, c001),
            (c100, c110), (c100, c101),
            (c010, c110), (c010, c011),
            (c001, c101), (c001, c011),
            (c110, c111),
            (c101, c111),
            (c011, c111)
        ]

        let node = SCNNode()
        node.name = name

        for (a, b) in edges {
            let seg = makeTubeSegment(
                from: toScene(a),
                to: toScene(b),
                color: color,
                radius: thickness
            )
            node.addChildNode(seg)
        }

        return node
    }

    // MARK: - Axes RGB

    private func makeAxesNode(axisLength: Float, thickness: CGFloat, name: String) -> SCNNode {
        let node = SCNNode()
        node.name = name

        let origin = SCNVector3(-0.5, -0.5, -0.5)
        let l = CGFloat(axisLength)

        let xEnd = SCNVector3(origin.x + l, origin.y, origin.z)
        let yEnd = SCNVector3(origin.x, origin.y + l, origin.z)
        let zEnd = SCNVector3(origin.x, origin.y, origin.z + l)

        node.addChildNode(makeTubeSegment(from: origin, to: xEnd, color: .systemRed,   radius: thickness))
        node.addChildNode(makeTubeSegment(from: origin, to: yEnd, color: .systemGreen, radius: thickness))
        node.addChildNode(makeTubeSegment(from: origin, to: zEnd, color: .systemBlue,  radius: thickness))

        return node
    }

    // MARK: - Point cloud

    private func makePointCloudNode(
        samplesPerAxis: Int,
        transform: (SIMD3<Float>) -> SIMD3<Float>,
        name: String
    ) -> SCNNode {

        let n = max(2, samplesPerAxis)
        let count = n * n * n

        var positions: [SIMD3<Float>] = []
        positions.reserveCapacity(count)

        var colors: [SIMD4<Float>] = []
        colors.reserveCapacity(count)

        for bz in 0..<n {
            let b = Float(bz) / Float(n - 1)
            for gy in 0..<n {
                let g = Float(gy) / Float(n - 1)
                for rx in 0..<n {
                    let r = Float(rx) / Float(n - 1)

                    let input = SIMD3<Float>(r, g, b)
                    let out = clamp01(transform(input))

                    // Position in scene: centered cube (-0.5..0.5)
                    positions.append(SIMD3<Float>(out.x - 0.5, out.y - 0.5, out.z - 0.5))

                    // Color = original RGB (like reference)
                    colors.append(SIMD4<Float>(r, g, b, 1.0))
                }
            }
        }

        let vertexData = dataFromArray(positions)
        let colorData  = dataFromArray(colors)

        let vSource = SCNGeometrySource(
            data: vertexData,
            semantic: .vertex,
            vectorCount: positions.count,
            usesFloatComponents: true,
            componentsPerVector: 3,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD3<Float>>.stride
        )

        let cSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        // Indices 0..N-1
        var indices = Array(0..<positions.count).map { UInt32($0) }
        let indexData = Data(bytes: &indices, count: indices.count * MemoryLayout<UInt32>.size)

        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .point,
            primitiveCount: indices.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geo = SCNGeometry(sources: [vSource, cSource], elements: [element])

        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.readsFromDepthBuffer = true
        mat.writesToDepthBuffer = true
        geo.materials = [mat]

        let node = SCNNode(geometry: geo)
        node.name = name

        return node
    }

    // MARK: - Tube segment helper (for outline + axes)

    private func makeTubeSegment(from: SCNVector3, to: SCNVector3, color: NSColor, radius: CGFloat) -> SCNNode {
        let a = SIMD3<Float>(Float(from.x), Float(from.y), Float(from.z))
        let b = SIMD3<Float>(Float(to.x),   Float(to.y),   Float(to.z))

        let v = b - a
        let length = simd_length(v)
        if length < 0.00001 { return SCNNode() }

        let cyl = SCNCylinder(radius: radius, height: CGFloat(length))
        cyl.radialSegmentCount = 10

        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        cyl.materials = [mat]

        let node = SCNNode(geometry: cyl)
        node.position = SCNVector3(
            (from.x + to.x) * 0.5,
            (from.y + to.y) * 0.5,
            (from.z + to.z) * 0.5
        )

        let dir = simd_normalize(v)
        let q = simd_quatf(from: SIMD3<Float>(0,1,0), to: dir)
        node.simdOrientation = q

        return node
    }

    // MARK: - Helpers

    private func clamp01(_ v: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3<Float>(
            min(max(v.x, 0), 1),
            min(max(v.y, 0), 1),
            min(max(v.z, 0), 1)
        )
    }

    private func toScene(_ v: SIMD3<Float>) -> SCNVector3 {
        SCNVector3(v.x - 0.5, v.y - 0.5, v.z - 0.5)
    }

    private func dataFromArray<T>(_ array: [T]) -> Data {
        array.withUnsafeBytes { Data($0) }
    }
}
