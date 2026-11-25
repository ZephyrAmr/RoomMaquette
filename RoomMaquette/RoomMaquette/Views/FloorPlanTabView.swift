import SwiftUI
import simd

public enum FloorPlanClearLayerKind: String, Identifiable {
    case furniture = "Furniture & Fixtures"
    case doors = "Doors"
    case windows = "Windows"
    case openings = "Openings"
    case walls = "Walls"
    
    public var id: String { rawValue }
}

public struct FloorPlanTabView: View {
    public var room: MaquetteRoom
    public var selectedObjectId: UUID? = nil
    public var onSelectObject: ((UUID?) -> Void)? = nil
    public var onMoveObject: ((UUID, SIMD3<Float>) -> Void)? = nil
    public var onDrawWall: ((SIMD2<Float>, SIMD2<Float>) -> Void)? = nil
    public var onDeleteElement: ((UUID) -> Void)? = nil
    public var onClearLayer: ((FloorPlanClearLayerKind) -> Void)? = nil
    public var onImportPlan: (() -> Void)? = nil
    public var onAlignPlan: (() -> Void)? = nil
    
    @State private var displayMode: FloorPlanDisplayMode = .scannedPlan
    @State private var showGrid: Bool = true
    @State private var showDimensions: Bool = true
    @State private var isMetric: Bool = true
    @State private var layerSettings = FloorPlanLayerSettings()
    @State private var showLayersSheet: Bool = false
    @State private var isDrawingWall: Bool = false
    
    public init(
        room: MaquetteRoom,
        selectedObjectId: UUID? = nil,
        onSelectObject: ((UUID?) -> Void)? = nil,
        onMoveObject: ((UUID, SIMD3<Float>) -> Void)? = nil,
        onDrawWall: ((SIMD2<Float>, SIMD2<Float>) -> Void)? = nil,
        onDeleteElement: ((UUID) -> Void)? = nil,
        onClearLayer: ((FloorPlanClearLayerKind) -> Void)? = nil,
        onImportPlan: (() -> Void)? = nil,
        onAlignPlan: (() -> Void)? = nil
    ) {
        self.room = room
        self.selectedObjectId = selectedObjectId
        self.onSelectObject = onSelectObject
        self.onMoveObject = onMoveObject
        self.onDrawWall = onDrawWall
        self.onDeleteElement = onDeleteElement
        self.onClearLayer = onClearLayer
        self.onImportPlan = onImportPlan
        self.onAlignPlan = onAlignPlan
        let initialMode: FloorPlanDisplayMode = (room.importedPlan != nil && room.notes.hasPrefix("Created from imported plan:"))
            ? .compositeOverlay
            : .scannedPlan
        self._displayMode = State(initialValue: initialMode)
    }
    
    public var body: some View {
        ZStack {
            FloorPlan2DCanvas(
                room: room,
                importedPlan: room.importedPlan,
                displayMode: displayMode,
                showGrid: showGrid,
                showDimensions: showDimensions,
                isMetric: isMetric,
                selectedObjectId: selectedObjectId,
                isInteractiveEditing: true,
                layerSettings: layerSettings,
                isDrawingWall: isDrawingWall,
                onSelectObject: onSelectObject,
                onMoveObject: onMoveObject,
                onDrawWall: onDrawWall
            )
            
            VStack {
                // Top Floating Plan Selector / Draw Wall Banner
                if isDrawingWall {
                    HStack(spacing: 10) {
                        Image(systemName: "pencil.line")
                            .foregroundColor(.orange)
                        Text("Tap start & end points to draw wall (snaps to corners)")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Button("Done") {
                            isDrawingWall = false
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange, in: Capsule())
                        .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)
                    .padding(.top, 8)
                } else {
                    HStack(spacing: 8) {
                        if room.importedPlan != nil {
                            Picker("Plan Mode", selection: $displayMode) {
                                Text("Scan").tag(FloorPlanDisplayMode.scannedPlan)
                                Text("Blueprint").tag(FloorPlanDisplayMode.importedBlueprint)
                                Text("Composite").tag(FloorPlanDisplayMode.compositeOverlay)
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 230)
                            
                            Button {
                                onAlignPlan?()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "slider.horizontal.2.square")
                                    Text("Align / Scale")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundColor(.blue)
                            }
                        } else {
                            Button {
                                onImportPlan?()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.badge.plus")
                                    Text("Import Architectural Plan")
                                        .font(.system(size: 12, weight: .bold))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.ultraThinMaterial, in: Capsule())
                                .foregroundColor(.blue)
                                .shadow(radius: 2)
                            }
                        }
                        
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                }
                
                Spacer()
                
                // Floating Toolbar at the bottom
                HStack(spacing: 10) {
                    // Layers Button
                    Button {
                        showLayersSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.3.layers.3d")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Layers")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .background(hasHiddenLayer ? Color.orange : Color(UIColor.secondarySystemGroupedBackground))
                        .foregroundColor(hasHiddenLayer ? .white : .primary)
                        .clipShape(Capsule())
                        .shadow(radius: 2)
                    }
                    
                    // Tap-to-Draw Wall Toggle
                    if onDrawWall != nil {
                        Button {
                            withAnimation {
                                isDrawingWall.toggle()
                                if isDrawingWall {
                                    onSelectObject?(nil)
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "pencil.line")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Wall")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .padding(.horizontal, 11)
                            .padding(.vertical, 9)
                            .background(isDrawingWall ? Color.orange : Color(UIColor.secondarySystemGroupedBackground))
                            .foregroundColor(isDrawingWall ? .white : .primary)
                            .clipShape(Capsule())
                            .shadow(radius: 2)
                        }
                    }
                    
                    // Grid Toggle
                    Button {
                        showGrid.toggle()
                    } label: {
                        Image(systemName: showGrid ? "grid" : "square")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(10)
                            .background(showGrid ? Color.blue : Color(UIColor.secondarySystemGroupedBackground))
                            .foregroundColor(showGrid ? .white : .primary)
                            .clipShape(Circle())
                            .shadow(radius: 2)
                    }
                    
                    // Dimensions Toggle
                    Button {
                        showDimensions.toggle()
                    } label: {
                        Image(systemName: showDimensions ? "ruler.fill" : "ruler")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(10)
                            .background(showDimensions ? Color.blue : Color(UIColor.secondarySystemGroupedBackground))
                            .foregroundColor(showDimensions ? .white : .primary)
                            .clipShape(Circle())
                            .shadow(radius: 2)
                    }
                    
                    // Metric / Imperial Toggle
                    Button {
                        isMetric.toggle()
                    } label: {
                        Text(isMetric ? "M" : "FT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                            .shadow(radius: 2)
                    }
                }
                .padding(.bottom, 22)
            }
        }
        .sheet(isPresented: $showLayersSheet) {
            FloorPlanLayersSheet(
                room: room,
                layerSettings: $layerSettings,
                onSelectItem: { id in
                    showLayersSheet = false
                    onSelectObject?(id)
                },
                onDeleteItem: { id in
                    onDeleteElement?(id)
                },
                onClearLayer: { kind in
                    onClearLayer?(kind)
                }
            )
        }
    }
    
    private var hasHiddenLayer: Bool {
        !layerSettings.showWalls || !layerSettings.showDoors || !layerSettings.showWindows ||
        !layerSettings.showOpenings || !layerSettings.showFurniture || !layerSettings.showBlueprint
    }
}

// MARK: - 2D Layers Management Sheet

public struct FloorPlanLayersSheet: View {
    @Environment(\.dismiss) private var dismiss
    public var room: MaquetteRoom
    @Binding public var layerSettings: FloorPlanLayerSettings
    public var onSelectItem: ((UUID) -> Void)?
    public var onDeleteItem: ((UUID) -> Void)?
    public var onClearLayer: ((FloorPlanClearLayerKind) -> Void)?
    
    @State private var pendingClearKind: FloorPlanClearLayerKind? = nil
    
    public var body: some View {
        NavigationStack {
            List {
                Section("2D PLAN LAYERS") {
                    layerRow(
                        title: "Walls",
                        icon: "square.split.diagonal.2x2",
                        color: .primary,
                        count: room.walls.count,
                        isVisible: $layerSettings.showWalls,
                        clearKind: .walls
                    )
                    layerRow(
                        title: "Furniture & Fixtures",
                        icon: "sofa.fill",
                        color: .orange,
                        count: room.objects.count,
                        isVisible: $layerSettings.showFurniture,
                        clearKind: .furniture
                    )
                    layerRow(
                        title: "Doors",
                        icon: "door.left.hand.open",
                        color: .blue,
                        count: room.doors.count,
                        isVisible: $layerSettings.showDoors,
                        clearKind: .doors
                    )
                    layerRow(
                        title: "Windows",
                        icon: "window.vertical.closed",
                        color: .cyan,
                        count: room.windows.count,
                        isVisible: $layerSettings.showWindows,
                        clearKind: .windows
                    )
                    layerRow(
                        title: "Openings",
                        icon: "rectangle.dashed",
                        color: .teal,
                        count: room.openings.count,
                        isVisible: $layerSettings.showOpenings,
                        clearKind: .openings
                    )
                    if room.importedPlan != nil {
                        Toggle(isOn: $layerSettings.showBlueprint) {
                            Label("Imported Blueprint", systemImage: "doc.richtext")
                        }
                    }
                }
                
                if !room.objects.isEmpty {
                    Section("FURNITURE LAYER ITEMS (\(room.objects.count))") {
                        ForEach(room.objects) { obj in
                            HStack {
                                Image(systemName: obj.category.systemIcon)
                                    .foregroundColor(obj.category.accentColor)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(obj.displayName)
                                        .font(.subheadline.weight(.medium))
                                    Text(String(format: "%.2fm × %.2fm", obj.width, obj.depth))
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button {
                                    onSelectItem?(obj.id)
                                } label: {
                                    Image(systemName: "scope")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.borderless)
                                
                                Button(role: .destructive) {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    onDeleteItem?(obj.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
                
                if !room.walls.isEmpty {
                    Section("WALL LAYER ITEMS (\(room.walls.count))") {
                        ForEach(room.walls) { wall in
                            HStack {
                                Image(systemName: "square.split.diagonal.2x2")
                                    .foregroundColor(.primary)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(wall.displayName)
                                        .font(.subheadline.weight(.medium))
                                    Text(String(format: "Len: %.2fm • Thick: %.2fm", wall.length, wall.thickness))
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button {
                                    onSelectItem?(wall.id)
                                } label: {
                                    Image(systemName: "scope")
                                        .foregroundColor(.blue)
                                }
                                .buttonStyle(.borderless)
                                
                                Button(role: .destructive) {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    onDeleteItem?(wall.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
            .navigationTitle("2D Plan Layers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(item: $pendingClearKind) { kind in
                Alert(
                    title: Text("Remove All \(kind.rawValue)?"),
                    message: Text("This will delete every item in the \(kind.rawValue) layer from this room."),
                    primaryButton: .destructive(Text("Remove All")) {
                        onClearLayer?(kind)
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }
    
    @ViewBuilder
    private func layerRow(
        title: String,
        icon: String,
        color: Color,
        count: Int,
        isVisible: Binding<Bool>,
        clearKind: FloorPlanClearLayerKind
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 22)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("\(count) item\(count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if count > 0 {
                Button(role: .destructive) {
                    pendingClearKind = clearKind
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .padding(6)
                        .background(Color.red.opacity(0.1), in: Circle())
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
            
            Button {
                isVisible.wrappedValue.toggle()
            } label: {
                Image(systemName: isVisible.wrappedValue ? "eye.fill" : "eye.slash.fill")
                    .font(.system(size: 14))
                    .foregroundColor(isVisible.wrappedValue ? .blue : .secondary)
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
        }
    }
}
