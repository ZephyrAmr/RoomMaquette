import SwiftUI
import SceneKit

public struct Maquette3DSceneView: UIViewRepresentable {
    public var room: MaquetteRoom
    public var style: MaquetteStyle
    public var showCeiling: Bool
    public var showMeasurements: Bool
    public var onSelectObject: ((String) -> Void)?
    
    public init(
        room: MaquetteRoom,
        style: MaquetteStyle = .architecturalClay,
        showCeiling: Bool = false,
        showMeasurements: Bool = false,
        onSelectObject: ((String) -> Void)? = nil
    ) {
        self.room = room
        self.style = style
        self.showCeiling = showCeiling
        self.showMeasurements = showMeasurements
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
            showMeasurements: showMeasurements
        )
        scnView.scene = scene
        
        // Tap recognizer for interactive object inspection
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        scnView.addGestureRecognizer(tap)
        context.coordinator.scnView = scnView
        
        return scnView
    }
    
    public func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
        // Rebuild scene when room, style, or toggles change
        uiView.scene = SceneKitMaquetteRenderer.buildScene(
            for: room,
            style: style,
            showCeiling: showCeiling,
            showMeasurements: showMeasurements
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
            guard let view = scnView else { return }
            let location = gesture.location(in: view)
            let hits = view.hitTest(location, options: [.rootNode: view.scene?.rootNode as Any])
            
            if let firstHit = hits.first, let name = firstHit.node.name, !name.isEmpty, name != "FloorPlinth" {
                parent.onSelectObject?(name)
            }
        }
    }
}
