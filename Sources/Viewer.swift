import AppKit
import MetalKit
import SwiftUI
import simd

private struct CameraUniforms {
    let right: SIMD4<Float>
    let up: SIMD4<Float>
    let forward: SIMD4<Float>
    let eye: SIMD4<Float>
    let viewport: SIMD4<Float>
}

@MainActor
final class OrbitView: MTKView {
    var renderer: SplatRenderer?
    private var lastDragLocation: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
        NSCursor.closedHand.push()
    }
    override func mouseUp(with event: NSEvent) {
        lastDragLocation = nil
        NSCursor.pop()
    }
    override func rightMouseDown(with event: NSEvent) {
        lastDragLocation = event.locationInWindow
    }
    override func rightMouseUp(with event: NSEvent) {
        lastDragLocation = nil
    }
    override func mouseDragged(with event: NSEvent) {
        drag(event, pan: event.modifierFlags.contains(.shift))
    }
    override func rightMouseDragged(with event: NSEvent) { drag(event, pan: true) }
    override func scrollWheel(with event: NSEvent) {
        let delta = Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.008 : 0.075)
        renderer?.zoom(by: min(0.35, max(-0.35, -delta)))
        needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        renderer?.zoom(by: -Float(event.magnification))
        needsDisplay = true
    }

    private func drag(_ event: NSEvent, pan: Bool) {
        let location = event.locationInWindow
        defer { lastDragLocation = location }
        guard let previous = lastDragLocation else { return }
        let dx = Float(location.x - previous.x)
        let dy = Float(previous.y - location.y)
        if pan { renderer?.pan(dx: dx, dy: dy, height: Float(max(1, bounds.height))) }
        else { renderer?.orbit(dx: dx, dy: dy) }
        needsDisplay = true
    }
}

@MainActor
final class SplatRenderer: NSObject, MTKViewDelegate {
    private let splat: Splat
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let vertices: MTLBuffer
    private let visible: [Int]
    private var target: SIMD3<Float>
    private var yaw: Float = 0.18
    private var pitch: Float = 0.12
    private var distance: Float
    private let bucketCount = 2048

    init(splat: Splat, device: MTLDevice) throws {
        guard let shader = Bundle.main.url(forResource: "Splats", withExtension: "metal"),
              let queue = device.makeCommandQueue(),
              let vertices = splat.points.withUnsafeBytes({ bytes in
                  device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count)
              }) else { throw StudioError("Couldn’t initialize the Metal viewer.") }
        let library = try device.makeLibrary(source: String(contentsOf: shader, encoding: .utf8), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "splatVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "splatFragment")
        let color = descriptor.colorAttachments[0]!
        color.pixelFormat = .bgra8Unorm
        color.isBlendingEnabled = true
        color.sourceRGBBlendFactor = .one
        color.destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.sourceAlphaBlendFactor = .one
        color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.splat = splat
        self.device = device
        self.queue = queue
        self.vertices = vertices
        visible = splat.points.indices.filter { splat.points[$0].dcAndOpacity.w >= 1.0 / 255.0 }
        target = splat.center
        distance = splat.radius * 2.8
    }

    func reset() {
        yaw = 0.18
        pitch = 0.12
        target = splat.center
        distance = splat.radius * 2.8
    }

    func orbit(dx: Float, dy: Float) {
        yaw -= dx * 0.008
        pitch = min(1.55, max(-1.55, pitch + dy * 0.008))
    }

    func zoom(by amount: Float) {
        distance = min(splat.radius * 16, max(splat.radius * 0.12, distance * exp(amount)))
    }

    func pan(dx: Float, dy: Float, height: Float) {
        let camera = basis()
        let factor = distance / (height * 1.2)
        target += (-dx * camera.right + dy * camera.up) * factor
    }

    private func basis() -> (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let forward = -SIMD3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 1, 0)))
        return (right, simd_cross(right, forward), forward)
    }

    // Counting sort gives stable back-to-front compositing in O(n) per orbit frame.
    private func order(forward: SIMD3<Float>) -> MTLBuffer? {
        var buckets = [Int](repeating: 0, count: bucketCount)
        var pointBuckets = [Int](repeating: 0, count: visible.count)
        let span = splat.radius * 2
        for (i, index) in visible.enumerated() {
            let depth = simd_dot(splat.points[index].position - splat.center, forward)
            let normalized = min(1, max(0, 0.5 - depth / span))
            let bucket = Int(normalized * Float(bucketCount - 1))
            pointBuckets[i] = bucket
            buckets[bucket] += 1
        }
        var offset = 0
        for bucket in buckets.indices {
            let count = buckets[bucket]
            buckets[bucket] = offset
            offset += count
        }
        guard let buffer = device.makeBuffer(length: visible.count * MemoryLayout<UInt32>.stride) else { return nil }
        let indices = buffer.contents().bindMemory(to: UInt32.self, capacity: visible.count)
        for (i, index) in visible.enumerated() {
            let bucket = pointBuckets[i]
            indices[buckets[bucket]] = UInt32(index)
            buckets[bucket] += 1
        }
        return buffer
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let width = Float(view.drawableSize.width)
        let height = Float(view.drawableSize.height)
        guard width > 0, height > 0 else { return }
        let camera = basis()
        guard let order = order(forward: camera.forward),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniforms = CameraUniforms(
            right: SIMD4(camera.right, 0), up: SIMD4(camera.up, 0), forward: SIMD4(camera.forward, 0),
            eye: SIMD4(target - camera.forward * distance, 0),
            viewport: SIMD4(width, height, min(width, height) * 1.2, splat.radius * 0.02)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        encoder.setVertexBuffer(order, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CameraUniforms>.stride, index: 2)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: visible.count)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }
}

struct SplatViewer: NSViewRepresentable {
    let renderer: SplatRenderer
    let resetCount: Int

    func makeNSView(context: Context) -> OrbitView {
        let view = OrbitView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.066, green: 0.070, blue: 0.090, alpha: 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.renderer = renderer
        view.delegate = renderer
        return view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: OrbitView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 720, height: 570))
    }

    func updateNSView(_ view: OrbitView, context: Context) {
        if view.renderer !== renderer {
            view.renderer = renderer
            view.delegate = renderer
        }
        if context.coordinator.lastReset != resetCount {
            context.coordinator.lastReset = resetCount
            renderer.reset()
        }
        view.needsDisplay = true
    }

    final class Coordinator {
        var lastReset = 0
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
}
