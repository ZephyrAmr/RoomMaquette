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
        context.coordinator.recordSnapshot(from: self)
        
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        scnView.addGestureRecognizer(tap)
        context.coordinator.scnView = scnView
        
        return scnView
    }
    
    public func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.needsRebuild(for: self) else { return }
        
        let sameRoom = (context.coordinator.lastRoomId == room.id)
        let savedTransform = sameRoom ? uiView.pointOfView?.simdTransform : nil
        
        let newScene = SceneKitMaquetteRenderer.buildScene(
            for: room,
            style: style,
            showCeiling: showCeiling,
            showMeasurements: showMeasurements,
            selectedObjectId: selectedObjectId
        )
        
        if let saved = savedTransform,
           let camNode = newScene.rootNode.childNode(withName: "MainCamera", recursively: true) {
            camNode.simdTransform = saved
            uiView.scene = newScene
            uiView.pointOfView = camNode
        } else {
            uiView.scene = newScene
        }
        
        uiView.backgroundColor = style.sceneBackgroundColor
        context.coordinator.recordSnapshot(from: self)
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    public class Coordinator: NSObject {
        var parent: Maquette3DSceneView
        weak var scnView: SCNView?
        
        var lastRoomId: UUID?
        private var lastRoom: MaquetteRoom?
        private var lastStyle: MaquetteStyle?
        private var lastShowCeiling: Bool?
        private var lastShowMeasurements: Bool?
        private var lastSelectedObjectId: UUID?
        
        init(_ parent: Maquette3DSceneView) {
            self.parent = parent
        }
        
        func needsRebuild(for view: Maquette3DSceneView) -> Bool {
            return lastRoom != view.room ||
                   lastStyle != view.style ||
                   lastShowCeiling != view.showCeiling ||
                   lastShowMeasurements != view.showMeasurements ||
                   lastSelectedObjectId != view.selectedObjectId
        }
        
        func recordSnapshot(from view: Maquette3DSceneView) {
            lastRoomId = view.room.id
            lastRoom = view.room
            lastStyle = view.style
            lastShowCeiling = view.showCeiling
            lastShowMeasurements = view.showMeasurements
            lastSelectedObjectId = view.selectedObjectId
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
            
            parent.onSelectObject?(nil)
        }
    }
}
