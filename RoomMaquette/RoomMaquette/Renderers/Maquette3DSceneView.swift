import SwiftUI
import SceneKit

public struct Maquette3DSceneView: UIViewRepresentable {
    public var room: MaquetteRoom
    public var style: MaquetteStyle
    public var showCeiling: Bool
    public var showMeasurements: Bool
    public var selectedObjectId: UUID?
    public var onSelectObject: ((UUID?) -> Void)?
    
    public init(
        room: MaquetteRoom,
        style: MaquetteStyle = .architecturalClay,
        showCeiling: Bool = false,
        showMeasurements: Bool = false,
        selectedObjectId: UUID? = nil,
        onSelectObject: ((UUID?) -> Void)? = nil
    ) {
        self.room = room
        self.style = style
        self.showCeiling = showCeiling
        self.showMeasurements = showMeasurements
        self.selectedObjectId = selectedObjectId
        self.onSelectObject = onSelectObject
    }
    
    public func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = style.sceneBackgroundColor
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = false
        scnView.antialiasingMode = .multisampling4X
        scnView.rendersContinuously = false
        
        let scene = SceneKitMaquetteRenderer.buildScene(
            for: room,
            style: style,
            showCeiling: showCeiling,
            showMeasurements: showMeasurements,
            selectedObjectId: selectedObjectId
        )
        scnView.scene = scene
        
        // Tap recognizer for selecting objects in 3D
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        scnView.addGestureRecognizer(tap)
        context.coordinator.scnView = scnView
        
        return scnView
    }
    
    public func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
        // Rebuild scene when room, style, selection, or toggles change
        uiView.scene = SceneKitMaquetteRenderer.buildScene(
            for: room,
            style: style,
            showCeiling: showCeiling,
            showMeasurements: showMeasurements,
            selectedObjectId: selectedObjectId
        )
        uiView.backgroundColor = style.sceneBackgroundColor
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public class Coordinator: NSObject {
        var parent: Maquette3DSceneView
        weak var scnView: SCNView?
        
        init(_ parent: Maquette3DSceneView) {
            self.parent = parent
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = scnView, let root = view.scene?.rootNode else { return }
            let location = gesture.location(in: view)
            let hits = view.hitTest(location, options: [.rootNode: root])
            
            for hit in hits {
                var targetNode: SCNNode? = hit.node
                while targetNode != nil && targetNode != root {
                    if let name = targetNode?.name, name.contains("_"), !name.contains("FloorPlinth") {
                        let parts = name.split(separator: "_")
                        if let last = parts.last, let uuid = UUID(uuidString: String(last)) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            parent.onSelectObject?(uuid)
                            return
                        }
                    }
                    targetNode = targetNode?.parent
                }
            }
            
            // Tapping empty background or plinth clears selection
            parent.onSelectObject?(nil)
        }
    }
}
