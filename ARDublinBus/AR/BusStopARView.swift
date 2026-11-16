import RealityKit
import SwiftUI

/// Hosts RealityKit's `ARView`, driven by an `ARCoordinator`.
struct BusStopARView: UIViewRepresentable {
    let model: AppModel
    /// The view is covered by a sheet, so the session doesn't need to run.
    var isPaused = false

    func makeCoordinator() -> ARCoordinator {
        ARCoordinator(model: model)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        context.coordinator.attach(to: arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.setPaused(isPaused)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: ARCoordinator) {
        coordinator.stop()
    }
}
