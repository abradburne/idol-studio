import Foundation
import ImageIO
import SceneKit
import SwiftUI

// Reads the single indexed primitive and embedded textures emitted by Hunyuan3D.
struct TexturedMesh: Sendable {
    let glb: Data
    let vertexCount: Int
    let triangleCount: Int
    private let positions: Data
    private let normals: Data
    private let uv: Data
    private let indices: Data
    private let albedo: CGImage
    private let metallicRoughness: CGImage?
    private let metallicFactor: Double
    private let roughnessFactor: Double

    @concurrent
    static func read(_ glb: Data) async throws -> Self {
        try Self(glb: glb)
    }

    init(glb: Data) throws {
        let invalid = StudioError("The engine returned an invalid or untextured mesh GLB.")
        let document = try glb.withUnsafeBytes { bytes -> (Document, Range<Int>) in
            func word(_ offset: Int) -> Int {
                Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            guard bytes.count >= 28, word(0) == 0x46546C67, word(4) == 2,
                  word(8) == bytes.count, word(16) == 0x4E4F534A else { throw invalid }
            let jsonEnd = 20 + word(12)
            guard jsonEnd <= bytes.count - 8, word(jsonEnd + 4) == 0x004E4942,
                  word(jsonEnd) == bytes.count - jsonEnd - 8 else { throw invalid }
            return (try JSONDecoder().decode(Document.self, from: glb[20..<jsonEnd]), (jsonEnd + 8)..<bytes.count)
        }
        let (doc, bin) = document
        guard let primitive = doc.meshes.first?.primitives.first, primitive.mode == 4,
              doc.materials.indices.contains(primitive.material) else { throw invalid }
        let material = doc.materials[primitive.material].pbrMetallicRoughness

        func buffer(_ index: Int) throws -> Data {
            guard doc.bufferViews.indices.contains(index) else { throw invalid }
            let view = doc.bufferViews[index]
            let offset = view.byteOffset ?? 0
            guard view.buffer == 0, view.byteStride == nil, offset >= 0, offset <= bin.count,
                  view.byteLength >= 0, view.byteLength <= bin.count - offset else { throw invalid }
            return glb.subdata(in: (bin.lowerBound + offset)..<(bin.lowerBound + offset + view.byteLength))
        }

        func accessor(_ index: Int?, type: String, component: Int, width: Int) throws -> (Data, Int) {
            guard let index, doc.accessors.indices.contains(index) else { throw invalid }
            let access = doc.accessors[index]
            guard access.type == type, access.componentType == component, access.count > 0 else { throw invalid }
            let data = try buffer(access.bufferView)
            let offset = access.byteOffset ?? 0
            guard offset >= 0, offset <= data.count, access.count <= (data.count - offset) / width else { throw invalid }
            return (data.subdata(in: offset..<(offset + access.count * width)), access.count)
        }

        func texture(_ slot: Document.TextureSlot) throws -> CGImage {
            guard doc.textures.indices.contains(slot.index) else { throw invalid }
            let source = doc.textures[slot.index].source
            guard doc.images.indices.contains(source) else { throw invalid }
            let data = try buffer(doc.images[source].bufferView)
            guard let image = CGImageSourceCreateWithData(data as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(image, 0, nil) else { throw invalid }
            return decoded
        }

        let (positions, vertices) = try accessor(primitive.attributes["POSITION"], type: "VEC3", component: 5126, width: 12)
        let (normals, normalCount) = try accessor(primitive.attributes["NORMAL"], type: "VEC3", component: 5126, width: 12)
        let (uv, uvCount) = try accessor(primitive.attributes["TEXCOORD_0"], type: "VEC2", component: 5126, width: 8)
        let (indices, indexCount) = try accessor(primitive.indices, type: "SCALAR", component: 5125, width: 4)
        guard normalCount == vertices, uvCount == vertices, indexCount.isMultiple(of: 3),
              indices.withUnsafeBytes({ $0.bindMemory(to: UInt32.self).allSatisfy { UInt32(littleEndian: $0) < vertices } })
        else { throw invalid }

        self.glb = glb
        self.vertexCount = vertices
        self.triangleCount = indexCount / 3
        self.positions = positions
        self.normals = normals
        self.uv = uv
        self.indices = indices
        self.albedo = try texture(material.baseColorTexture)
        self.metallicRoughness = try material.metallicRoughnessTexture.map(texture)
        self.metallicFactor = material.metallicFactor ?? 1
        self.roughnessFactor = material.roughnessFactor ?? 1
    }

    @MainActor
    func makeScene() -> SCNScene {
        func source(_ data: Data, _ semantic: SCNGeometrySource.Semantic, _ components: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: data, semantic: semantic, vectorCount: vertexCount,
                              usesFloatComponents: true, componentsPerVector: components,
                              bytesPerComponent: 4, dataOffset: 0, dataStride: components * 4)
        }
        let element = SCNGeometryElement(data: indices, primitiveType: .triangles,
                                         primitiveCount: triangleCount, bytesPerIndex: 4)
        let geometry = SCNGeometry(sources: [
            source(positions, .vertex, 3), source(normals, .normal, 3), source(uv, .texcoord, 2)
        ], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = albedo
        if let metallicRoughness {
            material.metalness.contents = metallicRoughness
            material.metalness.textureComponents = .blue
            material.metalness.intensity = metallicFactor
            material.roughness.contents = metallicRoughness
            material.roughness.textureComponents = .green
            material.roughness.intensity = roughnessFactor
        } else {
            material.metalness.contents = metallicFactor
            material.roughness.contents = roughnessFactor
        }
        geometry.materials = [material]

        let scene = SCNScene()
        let model = SCNNode(geometry: geometry)
        let (low, high) = model.boundingBox
        let center = SCNVector3((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2)
        let extent = max(high.x - low.x, high.y - low.y, high.z - low.z, 0.001)
        model.scale = SCNVector3(1 / extent, 1 / extent, 1 / extent)
        model.position = SCNVector3(-center.x / extent, -center.y / extent, -center.z / extent)
        scene.rootNode.addChildNode(model)
        scene.lightingEnvironment.contents = NSColor(white: 0.8, alpha: 1)
        return scene
    }
}

private struct Document: Decodable {
    struct Accessor: Decodable {
        let bufferView: Int
        let byteOffset: Int?
        let componentType: Int
        let count: Int
        let type: String
    }

    struct BufferView: Decodable {
        let buffer: Int
        let byteOffset: Int?
        let byteLength: Int
        let byteStride: Int?
    }

    struct Primitive: Decodable {
        let attributes: [String: Int]
        let indices: Int
        let material: Int
        let mode: Int
    }

    struct Mesh: Decodable { let primitives: [Primitive] }
    struct Image: Decodable { let bufferView: Int }
    struct Texture: Decodable { let source: Int }
    struct TextureSlot: Decodable { let index: Int }
    struct Material: Decodable {
        struct PBR: Decodable {
            let baseColorTexture: TextureSlot
            let metallicRoughnessTexture: TextureSlot?
            let metallicFactor: Double?
            let roughnessFactor: Double?
        }

        let pbrMetallicRoughness: PBR
    }

    let accessors: [Accessor]
    let bufferViews: [BufferView]
    let meshes: [Mesh]
    let images: [Image]
    let textures: [Texture]
    let materials: [Material]
}

struct MeshViewer: NSViewRepresentable {
    let scene: SCNScene
    let resetCount: Int

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = NSColor(srgbRed: 0.067, green: 0.071, blue: 0.09, alpha: 1)
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        guard view.scene !== scene || context.coordinator.resetCount != resetCount else { return }
        context.coordinator.resetCount = resetCount
        let camera = context.coordinator.camera
        if view.scene !== scene {
            camera.removeFromParentNode()
            scene.rootNode.addChildNode(camera)
            view.scene = scene
        }
        view.defaultCameraController.stopInertia()
        camera.position = SCNVector3(0.55, 0.32, 1.65)
        camera.look(at: SCNVector3Zero)
        view.pointOfView = camera
        view.defaultCameraController.target = SCNVector3Zero
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        let camera = SCNNode()
        var resetCount: Int?

        init() {
            camera.camera = SCNCamera()
            camera.camera?.fieldOfView = 43
        }
    }
}
