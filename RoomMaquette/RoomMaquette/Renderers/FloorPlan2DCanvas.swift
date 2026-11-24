import SwiftUI
import simd

public enum FloorPlanDisplayMode: String, CaseIterable, Identifiable {
    case scannedPlan = "Scanned 2D"
    case importedBlueprint = "Blueprint"
    case compositeOverlay = "Composite"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .scannedPlan: return "square.split.diagonal.2x2"
        case .importedBlueprint: return "doc.richtext"
        case .compositeOverlay: return "square.2.layers.3d"
        }
    }
}

public struct FloorPlan2DCanvas: View {
    public var room: MaquetteRoom
    public var importedPlan: ImportedPlan? = nil
    public var displayMode: FloorPlanDisplayMode = .scannedPlan
    public var showGrid: Bool = true
    public var showDimensions: Bool = true
    public var isMetric: Bool = true
    public var selectedObjectId: UUID? = nil
    public var userPosition: SIMD3<Float>? = nil
    public var userHeading: Float? = nil
    public var userPositionIsInPlanSpace: Bool = false
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
        importedPlan: ImportedPlan? = nil,
        displayMode: FloorPlanDisplayMode = .scannedPlan,
        showGrid: Bool = true,
        showDimensions: Bool = true,
        isMetric: Bool = true,
        selectedObjectId: UUID? = nil,
        userPosition: SIMD3<Float>? = nil,
        userHeading: Float? = nil,
        userPositionIsInPlanSpace: Bool = false,
        isInteractiveEditing: Bool = true,
        onSelectObject: ((UUID?) -> Void)? = nil,
        onMoveObject: ((UUID, SIMD3<Float>) -> Void)? = nil,
        onTapPlanCoordinate: ((SIMD3<Float>) -> Void)? = nil
    ) {
        self.room = room
        self.importedPlan = importedPlan
        self.displayMode = displayMode
        self.showGrid = showGrid
        self.showDimensions = showDimensions
        self.isMetric = isMetric
        self.selectedObjectId = selectedObjectId
        self.userPosition = userPosition
        self.userHeading = userHeading
        self.userPositionIsInPlanSpace = userPositionIsInPlanSpace
        self.isInteractiveEditing = isInteractiveEditing
        self.onSelectObject = onSelectObject
        self.onMoveObject = onMoveObject
        self.onTapPlanCoordinate = onTapPlanCoordinate
    }
    
    public var body: some View {
        GeometryReader { proxy in
            let viewSize = proxy.size
            let bounds = room.boundingBox
            
            // Coordinate frame sizing
            let isBlueprint = (displayMode == .importedBlueprint && importedPlan != nil)
            let planW = CGFloat(isBlueprint ? max(importedPlan!.originalWidthMeters, 2.0) : max(bounds.max.x - bounds.min.x, 2.0))
            let planD = CGFloat(isBlueprint ? max(importedPlan!.originalDepthMeters, 2.0) : max(bounds.max.z - bounds.min.z, 2.0))
            let centerX = isBlueprint ? 0.0 : CGFloat(bounds.min.x + bounds.max.x) / 2.0
            let centerZ = isBlueprint ? 0.0 : CGFloat(bounds.min.z + bounds.max.z) / 2.0
            
            // Calculate base scale to fit room/blueprint nicely with padding
            let fitScaleX = (viewSize.width - 100) / planW
            let fitScaleY = (viewSize.height - 100) / planD
            let baseScale = min(fitScaleX, fitScaleY)
            let midX = viewSize.width / 2.0 + offset.width
            let midY = viewSize.height / 2.0 + offset.height
            let currentScale = baseScale * scale
            
            ZStack {
                // Background Blueprint Paper
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()
                
                // Optional Raster Blueprint Image Underlay
                if (displayMode == .importedBlueprint || displayMode == .compositeOverlay),
                   let plan = importedPlan,
                   let data = plan.renderedImageData,
                   let uiImage = UIImage(data: data) {
                    let isComposite = (displayMode == .compositeOverlay)
                    let invScale = isComposite ? CGFloat(1.0 / max(plan.alignment.scale, 0.001)) : 1.0
                    let imgW = CGFloat(plan.originalWidthMeters) * invScale * currentScale
                    let imgH = CGFloat(plan.originalDepthMeters) * invScale * currentScale
                    let imgRotation = isComposite ? Angle(radians: Double(-plan.alignment.rotationAngle)) : .zero
                    let planOriginInScan = isComposite ? plan.alignment.mapPlanToScan(point: .zero) : .zero
                    let imgCenterX = isComposite ? midX + (CGFloat(planOriginInScan.x) - centerX) * currentScale : midX
                    let imgCenterY = isComposite ? midY + (CGFloat(planOriginInScan.z) - centerZ) * currentScale : midY
                    
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: imgW, height: imgH)
                        .rotationEffect(imgRotation)
                        .position(x: imgCenterX, y: imgCenterY)
                        .opacity(displayMode == .compositeOverlay ? 0.55 : 0.95)
                        .shadow(color: Color.black.opacity(0.12), radius: 6)
                }
                
                Canvas { context, size in
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
                    
                    // 2. Draw Vector CAD Blueprint Lines if present
                    if (displayMode == .importedBlueprint || displayMode == .compositeOverlay),
                       let plan = importedPlan, !plan.vectorLines.isEmpty {
                        drawBlueprintVectorLines(
                            context: &context,
                            lines: plan.vectorLines,
                            alignment: plan.alignment,
                            isBlueprintSpace: displayMode == .importedBlueprint,
                            toCanvas: toCanvasPoint
                        )
                    }
                    
                    // 3. Draw Scanned Geometry when not in pure blueprint mode
                    if displayMode != .importedBlueprint {
                        // Floor Fill
                        drawFloorPolygon(context: &context, bounds: bounds, toCanvas: toCanvasPoint)
                        
                        // Furniture / Objects
                        drawFurniture(
                            context: &context,
                            objects: room.objects,
                            selectedId: selectedObjectId,
                            toCanvas: toCanvasPoint,
                            currentScale: currentScale
                        )
                        
                        // Walls, Doors, Windows
                        drawWalls(
                            context: &context,
                            walls: room.walls,
                            selectedId: selectedObjectId,
                            showDimensions: showDimensions,
                            toCanvas: toCanvasPoint,
                            currentScale: currentScale
                        )
                        drawDoors(
                            context: &context,
                            doors: room.doors,
                            selectedId: selectedObjectId,
                            showDimensions: showDimensions,
                            toCanvas: toCanvasPoint,
                            currentScale: currentScale
                        )
                        drawWindows(
                            context: &context,
                            windows: room.windows,
                            selectedId: selectedObjectId,
                            showDimensions: showDimensions,
                            toCanvas: toCanvasPoint,
                            currentScale: currentScale
                        )
                        drawOpenings(
                            context: &context,
                            openings: room.openings,
                            selectedId: selectedObjectId,
                            showDimensions: showDimensions,
                            toCanvas: toCanvasPoint
                        )
                        
                        // Dimension Lines
                        if showDimensions {
                            drawDimensions(context: &context, bounds: bounds, room: room, toCanvas: toCanvasPoint, currentScale: currentScale)
                        }
                        
                        // Room Name & Area Badge
                        drawRoomBadge(context: &context, room: room, toCanvas: toCanvasPoint)
                    }
                    
                    // 4. Live User Location Puck (Locate Me AR Mode)
                    if let userPos = userPosition {
                        if displayMode == .importedBlueprint, let plan = importedPlan {
                            if userPositionIsInPlanSpace {
                                let puckCanvas = toCanvasPoint(userPos.x, userPos.z)
                                drawUserLocationPuck(context: &context, center: puckCanvas, heading: userHeading)
                            } else {
                                // Map AR/scan position into imported blueprint coordinate space
                                let planPos = plan.alignment.mapScanToPlan(point: userPos)
                                let puckCanvas = toCanvasPoint(planPos.x, planPos.z)
                                let mappedHeading = userHeading.map { $0 + plan.alignment.rotationAngle }
                                drawUserLocationPuck(context: &context, center: puckCanvas, heading: mappedHeading)
                            }
                        } else if userPositionIsInPlanSpace, let plan = importedPlan {
                            let scanPos = plan.alignment.mapPlanToScan(point: userPos)
                            let puckCanvas = toCanvasPoint(scanPos.x, scanPos.z)
                            let mappedHeading = userHeading.map { $0 - plan.alignment.rotationAngle }
                            drawUserLocationPuck(context: &context, center: puckCanvas, heading: mappedHeading)
                        } else {
                            let puckCanvas = toCanvasPoint(userPos.x, userPos.z)
                            drawUserLocationPuck(context: &context, center: puckCanvas, heading: userHeading)
                        }
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
        let centerX: CGFloat = (displayMode == .importedBlueprint) ? 0.0 : CGFloat(bounds.min.x + bounds.max.x) / 2.0
        let centerZ: CGFloat = (displayMode == .importedBlueprint) ? 0.0 : CGFloat(bounds.min.z + bounds.max.z) / 2.0
        
        let rx = Float((screenPoint.x - midX) / currentScale + centerX)
        let rz = Float((screenPoint.y - midY) / currentScale + centerZ)
        
        if displayMode == .importedBlueprint, let plan = importedPlan {
            // Touch coordinate on blueprint inverted into AR/scan room space
            let planPt = SIMD3<Float>(rx, 0, rz)
            let scanPt = plan.alignment.mapPlanToScan(point: planPt)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onTapPlanCoordinate?(scanPt)
            return
        }
        
        let roomPt = SIMD3<Float>(rx, 0, rz)
        
        // 1. Check furniture object hits
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
        
        // 2. Check door hits
        for door in room.doors {
            let dx = roomPt.x - door.position.x
            let dz = roomPt.z - door.position.z
            let dist = sqrt(dx*dx + dz*dz)
            if dist <= max(door.width * 0.7, 0.45) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSelectObject?(door.id)
                return
            }
        }
        
        // 3. Check window hits
        for win in room.windows {
            let dx = roomPt.x - win.position.x
            let dz = roomPt.z - win.position.z
            let dist = sqrt(dx*dx + dz*dz)
            if dist <= max(win.width * 0.7, 0.45) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSelectObject?(win.id)
                return
            }
        }
        
        // 3b. Check opening hits
        for op in room.openings {
            let dx = roomPt.x - op.position.x
            let dz = roomPt.z - op.position.z
            let dist = sqrt(dx*dx + dz*dz)
            if dist <= max(op.width * 0.7, 0.45) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onSelectObject?(op.id)
                return
            }
        }
        
        // 4. Check wall hits (perpendicular distance to wall segment)
        for wall in room.walls {
            let p1 = wall.startPoint2D
            let p2 = wall.endPoint2D
            let wx = Float(p2.x - p1.x)
            let wz = Float(p2.y - p1.y)
            let lenSq = wx*wx + wz*wz
            if lenSq > 0.0001 {
                let t = max(0, min(1, ((roomPt.x - Float(p1.x)) * wx + (roomPt.z - Float(p1.y)) * wz) / lenSq))
                let projX = Float(p1.x) + t * wx
                let projZ = Float(p1.y) + t * wz
                let dist = sqrt((roomPt.x - projX)*(roomPt.x - projX) + (roomPt.z - projZ)*(roomPt.z - projZ))
                if dist <= 0.35 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSelectObject?(wall.id)
                    return
                }
            }
        }
        
        // Tap on empty space: notify plan coordinate and clear selection
        onTapPlanCoordinate?(roomPt)
        onSelectObject?(nil)
    }
    
    // MARK: - Drawing Functions
    
    private func drawBlueprintVectorLines(
        context: inout GraphicsContext,
        lines: [PlanLine],
        alignment: PlanAlignmentTransform,
        isBlueprintSpace: Bool,
        toCanvas: (Float, Float) -> CGPoint
    ) {
        var path = Path()
        for line in lines {
            let p1: CGPoint
            let p2: CGPoint
            if isBlueprintSpace {
                p1 = toCanvas(line.startX, line.startZ)
                p2 = toCanvas(line.endX, line.endZ)
            } else {
                let startScan = alignment.mapPlanToScan(point: SIMD3<Float>(line.startX, 0, line.startZ))
                let endScan = alignment.mapPlanToScan(point: SIMD3<Float>(line.endX, 0, line.endZ))
                p1 = toCanvas(startScan.x, startScan.z)
                p2 = toCanvas(endScan.x, endScan.z)
            }
            path.move(to: p1)
            path.addLine(to: p2)
        }
        context.stroke(
            path,
            with: .color(Color.blue.opacity(0.85)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
        )
    }
    
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
        selectedId: UUID?,
        showDimensions: Bool,
        toCanvas: (Float, Float) -> CGPoint,
        currentScale: CGFloat
    ) {
        for wall in walls {
            let s = wall.startPoint2D
            let e = wall.endPoint2D
            let startCanvas = toCanvas(Float(s.x), Float(s.y))
            let endCanvas = toCanvas(Float(e.x), Float(e.y))
            
            let isSelected = (wall.id == selectedId)
            let wallPixelThick = max(CGFloat(wall.thickness) * currentScale, 5.0)
            
            var path = Path()
            path.move(to: startCanvas)
            path.addLine(to: endCanvas)
            
            // Wall stroke
            context.stroke(
                path,
                with: .color(isSelected ? Color.blue : Color(UIColor.label)),
                style: StrokeStyle(lineWidth: wallPixelThick, lineCap: .square, lineJoin: .miter)
            )
            
            // If selected, draw outline highlight
            if isSelected {
                context.stroke(
                    path,
                    with: .color(Color.blue.opacity(0.35)),
                    style: StrokeStyle(lineWidth: wallPixelThick + 8, lineCap: .round)
                )
            }
            
            // Per-wall measurement badge along wall line
            if showDimensions {
                let dx = endCanvas.x - startCanvas.x
                let dy = endCanvas.y - startCanvas.y
                let segLen = sqrt(dx*dx + dy*dy)
                
                if segLen > 28 {
                    let midP = CGPoint(x: (startCanvas.x + endCanvas.x)/2.0, y: (startCanvas.y + endCanvas.y)/2.0)
                    let normalX = -dy / segLen
                    let normalY = dx / segLen
                    let offsetDist: CGFloat = 16.0
                    let badgeCenter = CGPoint(x: midP.x + normalX * offsetDist, y: midP.y + normalY * offsetDist)
                    
                    let distText = isMetric ? String(format: "%.2f m", wall.length) : String(format: "%.1f ft", wall.length * 3.28084)
                    
                    // Pill background for dimension badge
                    let pillW: CGFloat = 52.0
                    let pillH: CGFloat = 17.0
                    let pillRect = CGRect(x: badgeCenter.x - pillW/2, y: badgeCenter.y - pillH/2, width: pillW, height: pillH)
                    let pillPath = Path(roundedRect: pillRect, cornerRadius: 4.0)
                    
                    context.fill(pillPath, with: .color(Color(UIColor.systemBackground).opacity(0.92)))
                    context.stroke(pillPath, with: .color(isSelected ? Color.blue : Color(UIColor.separator)), lineWidth: 1.0)
                    
                    context.draw(
                        Text(distText)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(isSelected ? Color.blue : Color.primary),
                        at: badgeCenter,
                        anchor: .center
                    )
                }
            }
        }
    }
    
    private func drawDoors(
        context: inout GraphicsContext,
        doors: [DoorSurface],
        selectedId: UUID?,
        showDimensions: Bool,
        toCanvas: (Float, Float) -> CGPoint,
        currentScale: CGFloat
    ) {
        for door in doors {
            let pos = door.position
            let rot = door.transform.rotationY
            let w = door.width
            let hingeCanvas = toCanvas(pos.x - (w/2)*cos(rot), pos.z - (w/2)*sin(rot))
            let isSelected = (door.id == selectedId)
            
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
                with: .color(isSelected ? Color.blue : Color.blue.opacity(0.8)),
                style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, dash: [4, 3])
            )
            
            let swingAngle = baseAngle + Angle(degrees: 90)
            let leafEnd = CGPoint(
                x: hingeCanvas.x + radius * CGFloat(cos(swingAngle.radians)),
                y: hingeCanvas.y + radius * CGFloat(sin(swingAngle.radians))
            )
            var leafPath = Path()
            leafPath.move(to: hingeCanvas)
            leafPath.addLine(to: leafEnd)
            context.stroke(leafPath, with: .color(isSelected ? Color.blue : Color.blue), lineWidth: isSelected ? 3.5 : 2)
            
            if isSelected {
                // Draw hinge circle handle
                let hingeRect = CGRect(x: hingeCanvas.x - 5, y: hingeCanvas.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: hingeRect), with: .color(Color.blue))
            }
            
            // Door clearance dimension
            if showDimensions {
                let doorCenter = toCanvas(pos.x, pos.z)
                let dimText = isMetric ? String(format: "%.2f m", door.width) : String(format: "%.1f ft", door.width * 3.28084)
                context.draw(
                    Text("Door \(dimText)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.blue),
                    at: CGPoint(x: doorCenter.x, y: doorCenter.y - 12),
                    anchor: .center
                )
            }
        }
    }
    
    private func drawWindows(
        context: inout GraphicsContext,
        windows: [WindowSurface],
        selectedId: UUID?,
        showDimensions: Bool,
        toCanvas: (Float, Float) -> CGPoint,
        currentScale: CGFloat
    ) {
        for win in windows {
            let pos = win.position
            let rot = win.transform.rotationY
            let halfW = win.width / 2.0
            let isSelected = (win.id == selectedId)
            
            let p1 = toCanvas(pos.x - halfW * cos(rot), pos.z - halfW * sin(rot))
            let p2 = toCanvas(pos.x + halfW * cos(rot), pos.z + halfW * sin(rot))
            
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            
            context.stroke(
                path,
                with: .color(isSelected ? Color.blue : Color.cyan),
                lineWidth: isSelected ? 5.5 : 3.5
            )
            
            if isSelected {
                context.stroke(
                    path,
                    with: .color(Color.blue.opacity(0.35)),
                    lineWidth: 10.0
                )
            }
            
            // Window dimension
            if showDimensions {
                let winCenter = toCanvas(pos.x, pos.z)
                let dimText = isMetric ? String(format: "%.2f m", win.width) : String(format: "%.1f ft", win.width * 3.28084)
                context.draw(
                    Text("Win \(dimText)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.cyan),
                    at: CGPoint(x: winCenter.x, y: winCenter.y - 10),
                    anchor: .center
                )
            }
        }
    }
    
    private func drawOpenings(
        context: inout GraphicsContext,
        openings: [OpeningSurface],
        selectedId: UUID?,
        showDimensions: Bool,
        toCanvas: (Float, Float) -> CGPoint
    ) {
        for op in openings {
            let pos = op.position
            let rot = op.transform.rotationY
            let halfW = op.width / 2.0
            let isSelected = (op.id == selectedId)
            
            let p1 = toCanvas(pos.x - halfW * cos(rot), pos.z - halfW * sin(rot))
            let p2 = toCanvas(pos.x + halfW * cos(rot), pos.z + halfW * sin(rot))
            
            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            
            context.stroke(
                path,
                with: .color(isSelected ? Color.blue : Color.teal),
                style: StrokeStyle(lineWidth: isSelected ? 4.5 : 3.0, lineCap: .butt, dash: [5, 4])
            )
            
            if showDimensions {
                let opCenter = toCanvas(pos.x, pos.z)
                let dimText = isMetric ? String(format: "%.2f m", op.width) : String(format: "%.1f ft", op.width * 3.28084)
                context.draw(
                    Text("Open \(dimText)")
                        .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                        .foregroundColor(Color.teal),
                    at: CGPoint(x: opCenter.x, y: opCenter.y - 10),
                    anchor: .center
                )
            }
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
            let beamDistance: CGFloat = 46.0
            let fovHalfAngle: Double = 25.0 * .pi / 180.0 // 25 degrees in radians
            let headRad = Double(heading)
            
            var conePath = Path()
            conePath.move(to: center)
            conePath.addArc(
                center: center,
                radius: beamDistance,
                startAngle: Angle(radians: headRad - fovHalfAngle),
                endAngle: Angle(radians: headRad + fovHalfAngle),
                clockwise: false
            )
            conePath.closeSubpath()
            
            context.fill(conePath, with: .color(Color.blue.opacity(0.20)))
            context.stroke(conePath, with: .color(Color.blue.opacity(0.40)), lineWidth: 1.5)
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
