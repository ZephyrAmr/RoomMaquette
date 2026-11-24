import UIKit
import SceneKit
import simd

public class SceneKitMaquetteRenderer {
    
    public static func buildScene(
        for room: MaquetteRoom,
        style: MaquetteStyle = .architecturalClay,
        showCeiling: Bool = false,
        showMeasurements: Bool = false,
        selectedObjectId: UUID? = nil
    ) -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = style.sceneBackgroundColor
        
        let root = scene.rootNode
        let bounds = room.boundingBox
        let center = (bounds.min + bounds.max) / 2.0
        
        // 1. Lighting Setup (Museum Maquette Lighting)
        setupLighting(root: root, style: style, center: center)
        
        // 2. Base Pedestal / Floor Slab
        buildFloorPlinth(root: root, bounds: bounds, style: style)
        
        // 3. Wall Geometries
        buildWalls(root: root, walls: room.walls, style: style)
        
        // 4. Windows
        buildWindows(root: root, windows: room.windows, style: style)
        
        // 5. Doors
        buildDoors(root: root, doors: room.doors, style: style)
        
        // 6. Furniture & Objects
        buildFurniture(root: root, objects: room.objects, style: style, selectedId: selectedObjectId)
        
        // 7. Ceiling (if enabled)
        if showCeiling {
            buildCeiling(root: root, bounds: bounds, style: style)
        }
        
        // 8. 3D Measurement Lines (if enabled)
        if showMeasurements {
            buildMeasurementLines(root: root, room: room)
        }
        
        // 9. Camera setup
        setupDefaultCamera(root: root, bounds: bounds, center: center)
        
        return scene
    }
    
    // MARK: - Lighting
    private static func setupLighting(root: SCNNode, style: MaquetteStyle, center: SIMD3<Float>) {
        // Ambient Light
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = style == .technicalBlueprint ?
            UIColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1.0) :
            UIColor(white: 0.55, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        root.addChildNode(ambientNode)
        
        // Key Directional Light with soft shadows
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.castsShadow = true
        keyLight.shadowMode = .deferred
        keyLight.shadowSampleCount = 16
        keyLight.shadowRadius = 4.0
        keyLight.color = UIColor(white: 0.9, alpha: 1.0)
        let keyLightNode = SCNNode()
        keyLightNode.light = keyLight
        keyLightNode.position = SCNVector3(center.x + 8, 12, center.z + 8)
        keyLightNode.look(at: SCNVector3(center.x, 0, center.z))
        root.addChildNode(keyLightNode)
        
        // Soft Fill Light
        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.castsShadow = false
        fillLight.color = UIColor(white: 0.35, alpha: 1.0)
        let fillLightNode = SCNNode()
        fillLightNode.light = fillLight
        fillLightNode.position = SCNVector3(center.x - 8, 8, center.z - 8)
        fillLightNode.look(at: SCNVector3(center.x, 0, center.z))
        root.addChildNode(fillLightNode)
    }
    
    // MARK: - Floor Pedestal
    private static func buildFloorPlinth(root: SCNNode, bounds: (min: SIMD3<Float>, max: SIMD3<Float>), style: MaquetteStyle) {
        let margin: Float = 0.6
        let width = CGFloat((bounds.max.x - bounds.min.x) + margin * 2)
        let depth = CGFloat((bounds.max.z - bounds.min.z) + margin * 2)
        let height: CGFloat = 0.08
        
        let plinthGeo = SCNBox(width: width, height: height, length: depth, chamferRadius: 0.015)
        plinthGeo.firstMaterial = style.floorMaterial
        
        let plinthNode = SCNNode(geometry: plinthGeo)
        let centerX = Float(bounds.min.x + bounds.max.x) / 2.0
        let centerZ = Float(bounds.min.z + bounds.max.z) / 2.0
        plinthNode.position = SCNVector3(centerX, -Float(height)/2.0, centerZ)
        plinthNode.name = "FloorPlinth"
        root.addChildNode(plinthNode)
    }
    
    // MARK: - Walls
    private static func buildWalls(root: SCNNode, walls: [WallSurface], style: MaquetteStyle) {
        for wall in walls {
            let width = CGFloat(wall.length)
            let height = CGFloat(wall.height)
            let thickness = CGFloat(wall.thickness)
            
            let box = SCNBox(width: width, height: height, length: thickness, chamferRadius: 0.01)
            box.firstMaterial = style.wallMaterial
            
            let node = SCNNode(geometry: box)
            node.simdTransform = wall.transform.matrix
            node.name = "Wall_\(wall.id.uuidString)"
            root.addChildNode(node)
        }
    }
    
    // MARK: - Windows
    private static func buildWindows(root: SCNNode, windows: [WindowSurface], style: MaquetteStyle) {
        for win in windows {
            let width = CGFloat(win.width)
            let height = CGFloat(win.height)
            let frameThick: CGFloat = 0.06
            
            // Glass pane
            let glassGeo = SCNBox(width: width, height: height, length: frameThick, chamferRadius: 0.005)
            glassGeo.firstMaterial = style.glassMaterial
            
            let winNode = SCNNode(geometry: glassGeo)
            winNode.simdTransform = win.transform.matrix
            winNode.name = "Window_\(win.id.uuidString)"
            root.addChildNode(winNode)
        }
    }
    
    // MARK: - Doors
    private static func buildDoors(root: SCNNode, doors: [DoorSurface], style: MaquetteStyle) {
        for door in doors {
            let width = CGFloat(door.width)
            let height = CGFloat(door.height)
            let thickness: CGFloat = 0.04
            
            let doorGeo = SCNBox(width: width, height: height, length: thickness, chamferRadius: 0.005)
            doorGeo.firstMaterial = style.doorMaterial
            
            let doorNode = SCNNode(geometry: doorGeo)
            doorNode.simdTransform = door.transform.matrix
            doorNode.name = "Door_\(door.id.uuidString)"
            root.addChildNode(doorNode)
        }
    }
    
    // MARK: - Furniture
    private static func buildFurniture(root: SCNNode, objects: [FurnitureObject], style: MaquetteStyle, selectedId: UUID? = nil) {
        for obj in objects {
            let w = CGFloat(obj.width)
            let h = CGFloat(obj.height)
            let d = CGFloat(obj.depth)
            
            let box = SCNBox(width: w, height: h, length: d, chamferRadius: 0.02)
            let isSelected = (obj.id == selectedId)
            
            if isSelected {
                let selMat = SCNMaterial()
                selMat.diffuse.contents = UIColor.systemBlue
                selMat.emission.contents = UIColor.systemBlue.withAlphaComponent(0.4)
                box.firstMaterial = selMat
            } else {
                box.firstMaterial = style.furnitureMaterial(for: obj.category)
            }
            
            let node = SCNNode(geometry: box)
            node.simdTransform = obj.transform.matrix
            node.name = "Object_\(obj.category.rawValue)_\(obj.id.uuidString)"
            
            if isSelected {
                let outlineBox = SCNBox(width: w + 0.03, height: h + 0.03, length: d + 0.03, chamferRadius: 0.02)
                let outlineMat = SCNMaterial()
                outlineMat.diffuse.contents = UIColor.white.withAlphaComponent(0.8)
                outlineMat.fillMode = .lines
                outlineBox.firstMaterial = outlineMat
                let outlineNode = SCNNode(geometry: outlineBox)
                node.addChildNode(outlineNode)
            }
            
            root.addChildNode(node)
        }
    }
    
    // MARK: - Ceiling
    private static func buildCeiling(root: SCNNode, bounds: (min: SIMD3<Float>, max: SIMD3<Float>), style: MaquetteStyle) {
        let width = CGFloat(bounds.max.x - bounds.min.x)
        let depth = CGFloat(bounds.max.z - bounds.min.z)
        let height: CGFloat = 0.08
        
        let ceilGeo = SCNBox(width: width, height: height, length: depth, chamferRadius: 0.01)
        ceilGeo.firstMaterial = style.wallMaterial
        
        let ceilNode = SCNNode(geometry: ceilGeo)
        let centerX = Float(bounds.min.x + bounds.max.x) / 2.0
        let centerZ = Float(bounds.min.z + bounds.max.z) / 2.0
        ceilNode.position = SCNVector3(centerX, bounds.max.y + Float(height)/2.0, centerZ)
        ceilNode.name = "Ceiling"
        root.addChildNode(ceilNode)
    }
    
    // MARK: - Measurement Dimension Lines
    private static func buildMeasurementLines(root: SCNNode, room: MaquetteRoom) {
        let b = room.boundingBox
        let y: Float = 0.02
        
        // Width measurement
        let p1 = SCNVector3(b.min.x, y, b.max.z + 0.3)
        let p2 = SCNVector3(b.max.x, y, b.max.z + 0.3)
        let line = createLineNode(from: p1, to: p2, color: .systemBlue)
        root.addChildNode(line)
        
        // Depth measurement
        let p3 = SCNVector3(b.max.x + 0.3, y, b.min.z)
        let p4 = SCNVector3(b.max.x + 0.3, y, b.max.z)
        let line2 = createLineNode(from: p3, to: p4, color: .systemBlue)
        root.addChildNode(line2)
    }
    
    private static func createLineNode(from start: SCNVector3, to end: SCNVector3, color: UIColor) -> SCNNode {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let dz = end.z - start.z
        let distance = sqrt(dx*dx + dy*dy + dz*dz)
        let cylinder = SCNCylinder(radius: 0.008, height: CGFloat(distance))
        cylinder.firstMaterial?.diffuse.contents = color
        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3((start.x + end.x)/2.0, (start.y + end.y)/2.0, (start.z + end.z)/2.0)
        if abs(dx) > abs(dz) {
            node.eulerAngles = SCNVector3(0, 0, Float.pi / 2.0)
        } else {
            node.eulerAngles = SCNVector3(Float.pi / 2.0, 0, 0)
        }
        return node
    }
    
    // MARK: - Camera Setup
    private static func setupDefaultCamera(root: SCNNode, bounds: (min: SIMD3<Float>, max: SIMD3<Float>), center: SIMD3<Float>) {
        let maxDim = max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z, 4.0)
        let distance = Float(maxDim) * 1.6
        
        let camera = SCNCamera()
        camera.usesOrthographicProjection = false
        camera.fieldOfView = 50
        camera.zNear = 0.1
        camera.zFar = 100
        
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(center.x + distance * 0.75, distance * 0.85, center.z + distance * 0.75)
        camNode.look(at: SCNVector3(center.x, center.y * 0.5, center.z))
        camNode.name = "MainCamera"
        root.addChildNode(camNode)
    }
    
    // MARK: - Snapshot Generation (Off-Screen Render)
    public static func snapshot(
        room: MaquetteRoom,
        style: MaquetteStyle = .architecturalClay,
        size: CGSize = CGSize(width: 1920, height: 1440),
        isOrthographic: Bool = false
    ) -> UIImage {
        let scene = buildScene(for: room, style: style)
        
        if isOrthographic {
            if let camNode = scene.rootNode.childNode(withName: "MainCamera", recursively: true),
               let cam = camNode.camera {
                cam.usesOrthographicProjection = true
                let b = room.boundingBox
                let maxDim = max(b.max.x - b.min.x, b.max.z - b.min.z)
                cam.orthographicScale = Double(maxDim * 0.75)
                let c = (b.min + b.max) / 2.0
                camNode.position = SCNVector3(c.x, 15, c.z)
                camNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            }
        }
        
        let renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}
