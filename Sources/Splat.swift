import Foundation
import simd

struct StudioError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Gaussian: Sendable {
    var position: SIMD3<Float>
    var rotation: SIMD4<Float>
    var scale: SIMD3<Float>
    var dcAndOpacity: SIMD4<Float>
}

struct Splat: Sendable {
    let glb: Data
    let points: [Gaussian]
    let center: SIMD3<Float>
    let radius: Float

    init(glb: Data) throws {
        let invalid = StudioError("The engine returned an invalid IDOL splat.")
        let decoded: [Gaussian] = try glb.withUnsafeBytes { bytes in
            func word(_ offset: Int) -> Int {
                Int(UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            guard bytes.count >= 28, word(0) == 0x46546c67, word(4) == 2,
                  word(8) == bytes.count, word(16) == 0x4e4f534a else { throw invalid }
            let jsonEnd = 20 + word(12)
            guard jsonEnd <= bytes.count - 8, word(jsonEnd + 4) == 0x004e4942,
                  word(jsonEnd) == bytes.count - jsonEnd - 8 else { throw invalid }
            let binary = jsonEnd + 8
            let doc = try JSONDecoder().decode(GLTF.self, from: glb[20..<jsonEnd])
            guard let primitive = doc.meshes.first?.primitives.first,
                  primitive.mode == 0,
                  let index = primitive.attributes["POSITION"], doc.accessors.indices.contains(index) else { throw invalid }
            let count = doc.accessors[index].count
            guard (1...1_048_576).contains(count) else { throw invalid }

            func layout(_ name: String, _ width: Int, _ type: String) throws -> (offset: Int, stride: Int) {
                guard let index = primitive.attributes[name], doc.accessors.indices.contains(index) else { throw invalid }
                let a = doc.accessors[index]
                guard doc.bufferViews.indices.contains(a.bufferView), a.componentType == 5126,
                      a.count == count, a.type == type else { throw invalid }
                let v = doc.bufferViews[a.bufferView]
                let start = a.byteOffset ?? 0
                let offset = v.byteOffset ?? 0
                let stride = v.byteStride ?? width * 4
                guard v.buffer == 0, start >= 0, offset >= 0, v.byteLength >= 0,
                      stride >= width * 4, stride <= 252,
                      offset <= bytes.count - binary,
                      v.byteLength <= bytes.count - binary - offset,
                      start <= v.byteLength,
                      (count - 1) * stride + width * 4 <= v.byteLength - start else { throw invalid }
                return (binary + offset + start, stride)
            }

            let position = try layout("POSITION", 3, "VEC3")
            let prefix = "KHR_gaussian_splatting:"
            let rotation = try layout(prefix + "ROTATION", 4, "VEC4")
            let scale = try layout(prefix + "SCALE", 3, "VEC3")
            let dc = try layout(prefix + "SH_DEGREE_0_COEF_0", 3, "VEC3")
            let opacity = try layout(prefix + "OPACITY", 1, "SCALAR")

            func float(_ offset: Int) -> Float { Float(bitPattern: UInt32(word(offset))) }
            func vector(_ offset: Int) -> SIMD3<Float> {
                SIMD3(float(offset), float(offset + 4), float(offset + 8))
            }
            var points = [Gaussian]()
            points.reserveCapacity(count)
            for i in 0..<count {
                let p = vector(position.offset + i * position.stride)
                let r = rotation.offset + i * rotation.stride
                let q = SIMD4(vector(r), float(r + 12))
                let s = vector(scale.offset + i * scale.stride)
                let color = vector(dc.offset + i * dc.stride)
                let alpha = float(opacity.offset + i * opacity.stride)
                guard (0..<3).allSatisfy({ p[$0].isFinite && s[$0].isFinite && s[$0] >= 0 && color[$0].isFinite }),
                      (0..<4).allSatisfy({ q[$0].isFinite }), alpha.isFinite else { throw invalid }
                points.append(Gaussian(position: p, rotation: q, scale: s, dcAndOpacity: SIMD4(color, alpha)))
            }
            return points
        }
        var low = SIMD3<Float>(repeating: .infinity)
        var high = -low
        for point in decoded where point.dcAndOpacity.w >= 0.05 {
            low = simd_min(low, point.position)
            high = simd_max(high, point.position)
        }
        guard low.x.isFinite else { throw StudioError("IDOL returned an empty splat. Try another image.") }
        self.glb = glb
        points = decoded
        center = (low + high) / 2
        radius = max(0.01, simd_length(high - low) / 2)
    }

    func ply() -> Data {
        let properties = [
            "x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2",
            "opacity", "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"
        ]
        let header = "ply\nformat binary_little_endian 1.0\nelement vertex \(points.count)\n"
            + properties.map { "property float \($0)\n" }.joined() + "end_header\n"
        var result = Data(header.utf8)
        result.reserveCapacity(result.count + points.count * properties.count * 4)
        var row = [Float](repeating: 0, count: properties.count)
        for point in points {
            let p = point.position
            let q = point.rotation
            let c = point.dcAndOpacity
            let a = min(1 - 1e-6, max(1e-6, c.w))
            // Match IDOL's reference PLY axes (+Y down) and scalar-first quaternions.
            row[0] = p.x; row[1] = -p.y; row[2] = -p.z
            row[6] = c.x; row[7] = c.y; row[8] = c.z
            row[9] = log(a / (1 - a))
            row[10] = log(max(1e-6, point.scale.x))
            row[11] = log(max(1e-6, point.scale.y))
            row[12] = log(max(1e-6, point.scale.z))
            row[13] = -q.x; row[14] = q.w; row[15] = -q.z; row[16] = q.y
            row.withUnsafeBytes { result.append(contentsOf: $0) }
        }
        return result
    }
}

private struct GLTF: Decodable {
    struct Mesh: Decodable {
        struct Primitive: Decodable {
            let mode: Int
            let attributes: [String: Int]
        }
        let primitives: [Primitive]
    }
    struct Accessor: Decodable {
        let bufferView: Int
        let byteOffset: Int?
        let componentType: Int
        let count: Int
        let type: String
    }
    struct View: Decodable {
        let buffer: Int
        let byteOffset: Int?
        let byteLength: Int
        let byteStride: Int?
    }
    let meshes: [Mesh]
    let accessors: [Accessor]
    let bufferViews: [View]
}
