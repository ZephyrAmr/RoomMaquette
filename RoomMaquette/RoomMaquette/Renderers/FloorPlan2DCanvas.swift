import SwiftUI
import simd

public struct FloorPlan2DCanvas: View {
    public var room: MaquetteRoom
    public var showGrid: Bool = true
    public var showDimensions: Bool = true
    public var isMetric: Bool = true
    public var selectedObjectId: UUID? = nil
    public var userPosition: SIMD3<Float>? = nil
    public var userHeading: Float? = nil
    public var isInteractiveEditing: Bool = true
    
    public var onSelectObject: ((UUID?) -> Void)? = nil
    public var onMoveObject: ((UUID, SIMD3<Float>) -> Void)? = nil
    public var onTapPlanCoordinate: ((SIMD3<Float>) -> Void)? = nil
    
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero
    
    public init(
        room: MaquetteRoom,
        showGrid: Bool = true,
        showDimensions: Bool = true,
        isMetric: Bool = true,
        selectedObjectId: UUID? = nil,
        userPosition: SIMD3<Float>? = nil,
        userHeading: Float? = nil,
        isInteractiveEditing: Bool = true,
        onSelectObject: ((UUID?) -> Void)? = nil,
        onMoveObject: ((UUID, SIMD3<Float>) -> Void)? = nil,
        onTapPlanCoordinate: ((SIMD3<Float>) -> Void)? = nil
    ) {
        self.room = room
        self.showGrid = showGrid
        self.showDimensions = showDimensions
        self.isMetric = isMetric
        self.selectedObjectId = selectedObjectId
        self.userPosition = userPosition
        self.userHeading = userHeading
        self.isInteractiveEditing = isInteractiveEditing
        self.onSelectObject = onSelectObject
        self.onMoveObject = onMoveObject
        self.onTapPlanCoordinate = onTapPlanCoordinate
    }
    
    public var body: some View {
        GeometryReader { proxy in
            let viewSize = proxy.size
            let bounds = room.boundingBox
            let roomW = max(bounds.max.x - bounds.min.x, 2.0)
            let roomD = max(bounds.max.z - bounds.min.z, 2.0)
            
            // Calculate base scale to fit room nicely with padding
            let fitScaleX = (viewSize.width - 100) / CGFloat(roomW)
            let fitScaleY = (viewSize.height - 100) / CGFloat(roomD)
            let baseScale = min(fitScaleX, fitScaleY)
            
            let centerX = CGFloat(bounds.min.x + bounds.max.x) / 2.0
            let centerZ = CGFloat(bounds.min.z + bounds.max.z) / 2.0
            
            ZStack {
                // Background Blueprint Paper
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()
                
                Canvas { context, size in
                    let midX = size.width / 2.0 + offset.width
                    let midY = size.height / 2.0 + offset.height
                    let currentScale = baseScale * scale
                    
                    func toCanvasPoint(_ rx: Float, _ rz: Float) -> CGPoint {
                        let dx = CGFloat(rx) - centerX
                        let dz = CGFloat(rz) - centerZ
                        return CGPoint(
                            x: midX + dx * currentScale,
                            y: midY + dz * currentScale
                        )
                    }
                    
                    // 1. Draw Architectural Grid
                    if showGrid {
                        drawGrid(context: &context, size: size, midX: midX, midY: midY, currentScale: currentScale)
                    }
                    
                    // 2. Draw Floor Fill
                    drawFloorPolygon(context: &context, bounds: bounds, toCanvas: toCanvasPoint)
                    
                    // 3. Draw Furniture / Objects
                    drawFurniture(
                        context: &context,
                        objects: room.objects,
                        selectedId: selectedObjectId,
                        toCanvas: toCanvasPoint,
                        currentScale: currentScale
                    )
                    
                    // 4. Draw Walls
                    drawWalls(context: &context, walls: room.walls, toCanvas: toCanvasPoint, currentScale: currentScale)
                    
                    // 5. Draw Doors
                    drawDoors(context: &context, doors: room.doors, toCanvas: toCanvasPoint, currentScale: currentScale)
                    
                    // 6. Draw Windows
                    drawWindows(context: &context, windows: room.windows, toCanvas: toCanvasPoint, currentScale: currentScale)
                    
                    // 7. Draw Dimension Lines
                    if showDimensions {
                        drawDimensions(context: &context, bounds: bounds, room: room, toCanvas: toCanvasPoint, currentScale: currentScale)
                    }
                    
                    // 8. Room Name & Area Badge
                    drawRoomBadge(context: &context, room: room, toCanvas: toCanvasPoint)
                    
                    // 9. Live User Location Puck (Locate Me AR Mode)
                    if let userPos = userPosition {
                        let puckCanvas = toCanvasPoint(userPos.x, userPos.z)
                        drawUserLocationPuck(context: &context, center: puckCanvas, heading: userHeading)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleTapAt(location, viewSize: viewSize, bounds: bounds, baseScale: baseScale)
                }
                .gesture(
                    SimultaneousGesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(0.4, min(lastScale * value, 5.0))
                            }
                            .onEnded { _ in
                                lastScale = scale
                            },
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: lastOffset.width + value.translation.width,
                                    height: lastOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                )
                
                // HUD Controls: Reset Zoom & Scale Indicator
                VStack {
                    HStack {
                        // North Arrow & Scale Bar
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: "location.north.circle.fill")
                                    .foregroundColor(.blue)
                                    .font(.system(size: 15))
                                Text("N")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundColor(.secondary)
                            }
                            
                            HStack(spacing: 4) {
                                Rectangle()
                                    .fill(Color.primary.opacity(0.8))
                                    .frame(width: max(baseScale * scale, 30), height: 2.5)
                                Text(isMetric ? "1 m" : "3 ft")
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        
                        Spacer()
                        
                        // Reset View Button
                        Button {
                            withAnimation(.spring()) {
                                scale = 1.0
                                offset = .zero
                                lastScale = 1.0
                                lastOffset = .zero
                            }
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(8)
                                .background(.ultraThinMaterial, in: Circle())
                                .foregroundColor(.primary)
                        }
                    }
                    Spacer()
                }
                .padding(10)
            }
        }
    }
    
    // MARK: - Tap & Hit Detection
    
    private func handleTapAt(
        _ screenPoint: CGPoint,
        viewSize: CGSize,
        bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
        baseScale: CGFloat
    ) {
        let midX = viewSize.width / 2.0 + offset.width
        let midY = viewSize.height / 2.0 + offset.height
        let currentScale = baseScale * scale
        let centerX = CGFloat(bounds.min.x + bounds.max.x) / 2.0
        let centerZ = CGFloat(bounds.min.z + bounds.max.z) / 2.0
        
        let rx = Float((screenPoint.x - midX) / currentScale + centerX)
        let rz = Float((screenPoint.y - midY) / currentScale + centerZ)
        let roomPt = SIMD3<Float>(rx, 0, rz)
        
        // Check furniture object hits
        for obj in room.objects {
            let dx = roomPt.x - obj.position.x
            let dz = roomPt.z - obj.position.z
            let rot = obj.rotationY
            
            // Un-rotate touch point to object local space
            let cosA = cos(-rot)
            let sinA = sin(-rot)
            let localX = dx * cosA - dz * sinA
            let localZ = dx * sinA + dz * cosA
            
            let halfW = (obj.width / 2.0) + 0.15 // padding for easy tapping
            let halfD = (obj.depth / 2.0) + 0.15
            
            if abs(localX) <= halfW && abs(localZ) <= halfD {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSelectObject?(obj.id)
                return
            }
        }
        
        // Tap on empty space: notify plan coordinate and clear selection
        onTapPlanCoordinate?(roomPt)
        onSelectObject?(nil)
    }
    
    // MARK: - Drawing Functions
    
    private func drawGrid(context: inout GraphicsContext, size: CGSize, midX: CGFloat, midY: CGFloat, currentScale: CGFloat) {
        let gridSpacing: CGFloat = currentScale * (isMetric ? 1.0 : 0.9144)
        guard gridSpacing > 15 else { return }
        
        var gridPath = Path()
        let startX = midX.truncatingRemainder(dividingBy: gridSpacing) - gridSpacing
        for x in stride(from: startX, to: size.width + gridSpacing, by: gridSpacing) {
            gridPath.move(to: CGPoint(x: x, y: 0))
            gridPath.addLine(to: CGPoint(x: x, y: size.height))
        }
        let startY = midY.truncatingRemainder(dividingBy: gridSpacing) - gridSpacing
        for y in stride(from: startY, to: size.height + gridSpacing, by: gridSpacing) {
            gridPath.move(to: CGPoint(x: 0, y: y))
            gridPath.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(gridPath, with: .color(Color.primary.opacity(0.06)), lineWidth: 1)
    }
    
    private func drawFloorPolygon(
        context: inout GraphicsContext,
        bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
        toCanvas: (Float, Float) -> CGPoint
    ) {
        let margin: Float = 0.05
        let p1 = toCanvas(bounds.min.x - margin, bounds.min.z - margin)
        let p2 = toCanvas(bounds.max.x + margin, bounds.min.z - margin)
        let p3 = toCanvas(bounds.max.x + margin, bounds.max.z + margin)
        let p4 = toCanvas(bounds.min.x - margin, bounds.max.z + margin)
        
        var floorPath = Path()
        floorPath.move(to: p1)
        floorPath.addLine(to: p2)
        floorPath.addLine(to: p3)
        floorPath.addLine(to: p4)
        floorPath.closeSubpath()
        
        context.fill(floorPath, with: .color(Color(UIColor.secondarySystemGroupedBackground)))
    }
    
    private func drawWalls(
        context: inout GraphicsContext,
        walls: [WallSurface],
        toCanvas: (Float, Float) -> CGPoint,
        currentScale: CGFloat
    ) {
        for wall in walls {
            let s = wall.startPoint2D
            let e = wall.endPoint2D
            let startCanvas = toCanvas(Float(s.x), Float(s.y))
            let endCanvas = toCanvas(Float(e.x), Float(e.y))
            
            let wallPixelThick = max(CGFloat(wall.thickness) * currentScale, 5.0)
            
            var path = Path()
            path.move(to: startCanvas)
            path.addLine(to: endCanvas)
            
            context.stroke(
                path,
                with: .color(Color(UIColor.label)),
                style: StrokeStyle(lineWidth: wallPixelThick, lineCap: .square, lineJoin: .miter)
            )
        }
    }
    
    private func drawDoors(
        context: inout GraphicsContext,
        doors: [DoorSurface],
        toCanvas: (Float, Float) -> CGPoint,
        currentScale: CGFloat
    ) {
        for door in doors {
            let pos = door.position
            let rot = door.transform.rotationY
            let w = door.width
            let hingeCanvas = toCanvas(pos.x - (w/2)*cos(rot), pos.z - (w/2)*sin(rot))
            
            let radius = CGFloat(w) * currentScale
            var arcPath = Path()
            let baseAngle = Angle(radians: Double(rot))
            arcPath.addArc(
                center: hingeCanvas,
                radius: radius,
                startAngle: baseAngle,
                endAngle: baseAngle + Angle(degrees: 90),
                clockwise: false
            )
            
            context.stroke(
                arcPath,
                with: .color(Color.blue.opacity(0.8)),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            
            let swingAngle = baseAngle + Angle(degrees: 90)
            let leafEnd = CGPoint(
                x: hingeCanvas.x + radius * CGFloat(cos(swingAngle.radians)),
                y: hingeCanvas.y + radius * CGFloat(sin(swingAngle.radians))
            )
            var leafPath = Path()
            leafPath.move(to: hingeCanvas)
            leafPath.addLine(to: leafEnd)
            context.stroke(leafPath, with: .color(Color.blue), lineWidth: 2)
        }
    }
    
    private func drawWindows(
        context: inout GraphicsContext,
        windows: [WindowSurface],
        toCanvas: (Float, Float) -> CGPoint,
        currentScale: CGFloat
    ) {
        for win in windows {
            let pos = win.position
            let rot = win.transform.rotationY
            let halfW = win.width / 2.0
            
            let p1 = toCanvas(pos.x - halfW * cos(rot), pos.z - halfW * sin(rot))
            let p2 = toCanvas(pos.x + halfW * cos(rot), pos.z + halfW * sin(rot))
            
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            
            context.stroke(path, with: .color(Color.cyan), lineWidth: 3.5)
        }
    }
    
    private func drawFurniture(
        context: inout GraphicsContext,
        objects: [FurnitureObject],
        selectedId: UUID?,
        toCanvas: (Float, Float) -> CGPoint,
        currentScale: CGFloat
    ) {
        for obj in objects {
            let center = toCanvas(obj.position.x, obj.position.z)
            let w = CGFloat(obj.width) * currentScale
            let d = CGFloat(obj.depth) * currentScale
            let rot = Double(obj.rotationY)
            let isSelected = (obj.id == selectedId)
            
            context.drawLayer { layerContext in
                layerContext.translateBy(x: center.x, y: center.y)
                layerContext.rotate(by: Angle(radians: rot))
                
                let rect = CGRect(x: -w/2, y: -d/2, width: w, height: d)
                let rounded = Path(roundedRect: rect, cornerRadius: 4)
                
                // Fill & Stroke
                layerContext.fill(rounded, with: .color(obj.category.accentColor.opacity(isSelected ? 0.35 : 0.18)))
                layerContext.stroke(rounded, with: .color(isSelected ? Color.blue : obj.category.accentColor.opacity(0.9)), lineWidth: isSelected ? 2.5 : 1.5)
                
                // Selection Bounding Box & Handles
                if isSelected {
                    let selectionBounds = rect.insetBy(dx: -6, dy: -6)
                    let dashStyle = StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 4])
                    layerContext.stroke(Path(roundedRect: selectionBounds, cornerRadius: 6), with: .color(Color.blue), style: dashStyle)
                    
                    // Corner handles
                    for pt in [
                        CGPoint(x: selectionBounds.minX, y: selectionBounds.minY),
                        CGPoint(x: selectionBounds.maxX, y: selectionBounds.minY),
                        CGPoint(x: selectionBounds.minX, y: selectionBounds.maxY),
                        CGPoint(x: selectionBounds.maxX, y: selectionBounds.maxY)
                    ] {
                        let handleRect = CGRect(x: pt.x - 3.5, y: pt.y - 3.5, width: 7, height: 7)
                        layerContext.fill(Path(ellipseIn: handleRect), with: .color(Color.white))
                        layerContext.stroke(Path(ellipseIn: handleRect), with: .color(Color.blue), lineWidth: 1.5)
                    }
                }
                
                drawObjectDetail(layerContext: &layerContext, category: obj.category, rect: rect)
            }
        }
    }
    
    private func drawObjectDetail(layerContext: inout GraphicsContext, category: ObjectCategory, rect: CGRect) {
        switch category {
        case .sofa:
            let back = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.28)
            layerContext.fill(Path(roundedRect: back, cornerRadius: 2), with: .color(Color.primary.opacity(0.12)))
        case .bed:
            let pillowW = rect.width * 0.38
            let pillowH = rect.height * 0.22
            let p1 = CGRect(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.06, width: pillowW, height: pillowH)
            let p2 = CGRect(x: rect.maxX - rect.width * 0.08 - pillowW, y: rect.minY + rect.height * 0.06, width: pillowW, height: pillowH)
            layerContext.stroke(Path(roundedRect: p1, cornerRadius: 2), with: .color(Color.primary.opacity(0.35)), lineWidth: 1)
            layerContext.stroke(Path(roundedRect: p2, cornerRadius: 2), with: .color(Color.primary.opacity(0.35)), lineWidth: 1)
        case .sink, .toilet, .bathtub:
            let inner = rect.insetBy(dx: 4, dy: 4)
            layerContext.stroke(Path(ellipseIn: inner), with: .color(Color.teal.opacity(0.6)), lineWidth: 1)
        case .table:
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            layerContext.stroke(path, with: .color(Color.primary.opacity(0.08)), lineWidth: 1)
        default:
            break
        }
    }
    
    private func drawDimensions(
        context: inout GraphicsContext,
        bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
        room: MaquetteRoom,
        toCanvas: (Float, Float) -> CGPoint,
        currentScale: CGFloat
    ) {
        let offsetM: Float = 0.45
        let hStart = toCanvas(bounds.min.x, bounds.min.z - offsetM)
        let hEnd = toCanvas(bounds.max.x, bounds.min.z - offsetM)
        
        var hLine = Path()
        hLine.move(to: hStart)
        hLine.addLine(to: hEnd)
        hLine.move(to: CGPoint(x: hStart.x, y: hStart.y - 5))
        hLine.addLine(to: CGPoint(x: hStart.x, y: hStart.y + 5))
        hLine.move(to: CGPoint(x: hEnd.x, y: hEnd.y - 5))
        hLine.addLine(to: CGPoint(x: hEnd.x, y: hEnd.y + 5))
        context.stroke(hLine, with: .color(Color.secondary), lineWidth: 1)
        
        let widthText = isMetric ? String(format: "%.2f m", room.roomWidth) : String(format: "%.1f ft", room.roomWidth * 3.28084)
        context.draw(
            Text(widthText).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.secondary),
            at: CGPoint(x: (hStart.x + hEnd.x)/2.0, y: hStart.y - 10),
            anchor: .center
        )
        
        let vStart = toCanvas(bounds.max.x + offsetM, bounds.min.z)
        let vEnd = toCanvas(bounds.max.x + offsetM, bounds.max.z)
        var vLine = Path()
        vLine.move(to: vStart)
        vLine.addLine(to: vEnd)
        vLine.move(to: CGPoint(x: vStart.x - 5, y: vStart.y))
        vLine.addLine(to: CGPoint(x: vStart.x + 5, y: vStart.y))
        vLine.move(to: CGPoint(x: vEnd.x - 5, y: vEnd.y))
        vLine.addLine(to: CGPoint(x: vEnd.x + 5, y: vEnd.y))
        context.stroke(vLine, with: .color(Color.secondary), lineWidth: 1)
        
        let depthText = isMetric ? String(format: "%.2f m", room.roomDepth) : String(format: "%.1f ft", room.roomDepth * 3.28084)
        context.draw(
            Text(depthText).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundColor(.secondary),
            at: CGPoint(x: vStart.x + 14, y: (vStart.y + vEnd.y)/2.0),
            anchor: .leading
        )
    }
    
    private func drawRoomBadge(
        context: inout GraphicsContext,
        room: MaquetteRoom,
        toCanvas: (Float, Float) -> CGPoint
    ) {
        let b = room.boundingBox
        let center = toCanvas((b.min.x + b.max.x)/2.0, (b.min.z + b.max.z)/2.0)
        
        let title = Text(room.name).font(.system(size: 12, weight: .bold)).foregroundColor(.primary)
        let area = Text(isMetric ? room.formattedAreaMetric : room.formattedAreaImperial)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
        
        context.draw(title, at: CGPoint(x: center.x, y: center.y - 7), anchor: .center)
        context.draw(area, at: CGPoint(x: center.x, y: center.y + 7), anchor: .center)
    }
    
    // MARK: - User Location Indicator (Apple Maps style puck with FOV cone)
    
    private func drawUserLocationPuck(context: inout GraphicsContext, center: CGPoint, heading: Float?) {
        // 1. Draw Directional Camera FOV Cone / Flashlight Beam
        if let heading = heading {
            let beamDistance: CGFloat = 45.0
            let fovHalfAngle: Double = 28.0
            let headDeg = Double(heading) * 180.0 / .pi
            
            var conePath = Path()
            conePath.move(to: center)
            conePath.addArc(
                center: center,
                radius: beamDistance,
                startAngle: Angle(degrees: headDeg - fovHalfAngle - 90),
                endAngle: Angle(degrees: headDeg + fovHalfAngle - 90),
                clockwise: false
            )
            conePath.closeSubpath()
            
            context.fill(conePath, with: .color(Color.blue.opacity(0.18)))
            context.stroke(conePath, with: .color(Color.blue.opacity(0.35)), lineWidth: 1)
        }
        
        // 2. Outer Pulse Halo
        let halo = Path(ellipseIn: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
        context.fill(halo, with: .color(Color.blue.opacity(0.22)))
        
        // 3. White Border Ring
        let ring = Path(ellipseIn: CGRect(x: center.x - 7.5, y: center.y - 7.5, width: 15, height: 15))
        context.fill(ring, with: .color(Color.white))
        
        // 4. Solid Blue Core Puck
        let core = Path(ellipseIn: CGRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11))
        context.fill(core, with: .color(Color.blue))
    }
}
