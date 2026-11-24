import SwiftUI
import QuickLook
import UniformTypeIdentifiers
import simd

public struct MaquetteWorkspaceView: View {
    public var initialRoom: MaquetteRoom
    @EnvironmentObject private var projectStore: ProjectStore
    
    @State private var room: MaquetteRoom
    @State private var selectedTab: Int = 0 // 0: 3D Maquette, 1: 2D Plan, 2: Specs
    @State private var maquetteStyle: MaquetteStyle = .architecturalClay
    @State private var showCeiling: Bool = false
    @State private var show3DDimensions: Bool = false
    @State private var showExportSheet: Bool = false
    @State private var showLocateMeSheet: Bool = false
    @State private var showAddElementSheet: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var showPlanMatchingSheet: Bool = false
    @State private var importErrorMessage: String? = nil
    @State private var showImportErrorAlert: Bool = false
    @State private var quickLookURL: URL? = nil
    @State private var selectedObjectId: UUID? = nil
    @State private var isPreparingAR: Bool = false
    @State private var arErrorMessage: String? = nil
    @State private var showARErrorAlert: Bool = false
    
    public init(room: MaquetteRoom) {
        self.initialRoom = room
        self._room = State(initialValue: room)
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            
            // Mode Selector
            Picker("View Mode", selection: $selectedTab) {
                Text("3D Maquette").tag(0)
                Text("2D Floor Plan").tag(1)
                Text("Schedule & Specs").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            
            // Main Content Area
            ZStack {
                switch selectedTab {
                case 0:
                    maquette3DContainer
                case 1:
                    floorPlanContainer
                case 2:
                    RoomMetricsView(room: room)
                default:
                    EmptyView()
                }
                
                // Floating Selected Item Inspector Overlay (appears in both 3D & 2D when an item is tapped)
                if let element = currentInspectableElement {
                    VStack {
                        Spacer()
                        SelectedItemInspectorView(
                            element: element,
                            onDelete: {
                                deleteSelectedElement(id: element.id)
                            },
                            onRotate: {
                                rotateSelectedElement(id: element.id)
                            },
                            onNudge: { dx, dz in
                                nudgeSelectedElement(id: element.id, dx: dx, dz: dz)
                            },
                            onDuplicate: {
                                duplicateSelectedElement(id: element.id)
                            },
                            onToggleState: {
                                toggleSelectedElementState(id: element.id)
                            },
                            onDeselect: {
                                selectedObjectId = nil
                            }
                        )
                        .padding(.bottom, 70)
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                // "Locate Me" Indoor Positioning Camera Button
                Button {
                    showLocateMeSheet = true
                } label: {
                    Label("Locate Me", systemImage: "location.viewfinder")
                        .fontWeight(.semibold)
                }
                
                // Architectural Blueprint Menu
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import Blueprint / Plan", systemImage: "doc.badge.plus")
                    }
                    
                    if room.importedPlan != nil {
                        Button {
                            showPlanMatchingSheet = true
                        } label: {
                            Label("Align Blueprint to Scan", systemImage: "slider.horizontal.2.square")
                        }
                        
                        Button(role: .destructive) {
                            withAnimation {
                                room.importedPlan = nil
                            }
                            persistRoom()
                        } label: {
                            Label("Remove Blueprint", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: room.importedPlan != nil ? "doc.richtext.fill" : "doc.badge.plus")
                }
                
                // Add Door / Window / Furniture Element Button
                Button {
                    showAddElementSheet = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                
                // Export Button
                Button {
                    showExportSheet = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheetView(room: room)
        }
        .sheet(isPresented: $showAddElementSheet) {
            AddArchitecturalElementSheet(
                onAddDoor: { width, height, isOpen in
                    addNewDoor(width: width, height: height, isOpen: isOpen)
                },
                onAddWindow: { width, height in
                    addNewWindow(width: width, height: height)
                },
                onAddFurniture: { template in
                    addNewFurniture(template: template)
                }
            )
        }
        .sheet(isPresented: $showPlanMatchingSheet) {
            if room.importedPlan != nil {
                PlanMatchingView(
                    room: room,
                    plan: Binding(
                        get: { room.importedPlan! },
                        set: { room.importedPlan = $0 }
                    ),
                    onSave: { newTransform in
                        room.importedPlan?.alignment = newTransform
                        persistRoom()
                    },
                    onApplyPlanRescale: { updatedPlan in
                        room.importedPlan = updatedPlan
                        if room.notes.hasPrefix("Created from imported plan:") {
                            room.walls = PlanImporter.synthesizeWalls(from: updatedPlan)
                        }
                        persistRoom()
                    }
                )
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.pdf, .image, .item, .data]
        ) { result in
            switch result {
            case .success(let url):
                handlePlanImport(from: url)
            case .failure(let error):
                importErrorMessage = error.localizedDescription
                showImportErrorAlert = true
            }
        }
        .fullScreenCover(isPresented: $showLocateMeSheet) {
            RoomLocateMeView(room: room)
        }
        .quickLookPreview($quickLookURL)
        .alert("Unable to Start AR", isPresented: $showARErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(arErrorMessage ?? "Could not prepare the 3D model for Augmented Reality preview.")
        }
        .alert("Import Error", isPresented: $showImportErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importErrorMessage ?? "Failed to import plan.")
        }
    }
    
    // MARK: - 3D Maquette Container with Floating Overlays
    
    private var maquette3DContainer: some View {
        ZStack {
            Maquette3DSceneView(
                room: room,
                style: maquetteStyle,
                showCeiling: showCeiling,
                showMeasurements: show3DDimensions,
                selectedObjectId: selectedObjectId,
                onSelectObject: { uuid in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.selectedObjectId = uuid
                    }
                }
            )
            .ignoresSafeArea(edges: .bottom)
            
            // Floating 3D Tool Controls
            VStack {
                HStack {
                    // Style Selector Pill Menu
                    Menu {
                        ForEach(MaquetteStyle.allCases) { style in
                            Button {
                                maquetteStyle = style
                            } label: {
                                Label(style.rawValue, systemImage: style.icon)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: maquetteStyle.icon)
                            Text(maquetteStyle.rawValue)
                                .font(.system(size: 12, weight: .bold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundColor(.primary)
                    }
                    
                    Spacer()
                    
                    // Quick Look AR Button
                    Button {
                        launchARQuickLook()
                    } label: {
                        HStack(spacing: 6) {
                            if isPreparingAR {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arkit")
                            }
                            Text("View in AR")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .foregroundColor(.blue)
                    }
                    .disabled(isPreparingAR)
                }
                .padding()
                
                Spacer()
                
                // Bottom floating toggles
                HStack(spacing: 12) {
                    // Ceiling Toggle
                    Button {
                        showCeiling.toggle()
                    } label: {
                        Image(systemName: showCeiling ? "roof.box.fill" : "roof.box")
                            .font(.system(size: 14))
                            .padding(10)
                            .background(showCeiling ? Color.blue : Color(UIColor.secondarySystemGroupedBackground))
                            .foregroundColor(showCeiling ? .white : .primary)
                            .clipShape(Circle())
                            .shadow(radius: 2)
                    }
                    
                    // 3D Dimension Lines Toggle
                    Button {
                        show3DDimensions.toggle()
                    } label: {
                        Image(systemName: show3DDimensions ? "ruler.fill" : "ruler")
                            .font(.system(size: 14))
                            .padding(10)
                            .background(show3DDimensions ? Color.blue : Color(UIColor.secondarySystemGroupedBackground))
                            .foregroundColor(show3DDimensions ? .white : .primary)
                            .clipShape(Circle())
                            .shadow(radius: 2)
                    }
                    
                    Spacer()
                    
                    // Quick Area Tag
                    Text("\(room.formattedAreaMetric)  •  \(room.formattedAreaImperial)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding()
                .padding(.bottom, 16)
            }
        }
    }
    
    // MARK: - 2D Floor Plan Container
    
    private var floorPlanContainer: some View {
        FloorPlanTabView(
            room: room,
            selectedObjectId: selectedObjectId,
            onSelectObject: { uuid in
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.selectedObjectId = uuid
                }
            },
            onMoveObject: { uuid, newPos in
                nudgeSelectedObjectTo(id: uuid, targetPos: newPos)
            },
            onImportPlan: {
                showFileImporter = true
            },
            onAlignPlan: {
                showPlanMatchingSheet = true
            }
        )
    }
    
    // MARK: - Selected Element Introspection
    
    private var currentInspectableElement: InspectableElement? {
        guard let id = selectedObjectId else { return nil }
        if let obj = room.objects.first(where: { $0.id == id }) {
            return .furniture(obj)
        } else if let door = room.doors.first(where: { $0.id == id }) {
            return .door(door)
        } else if let win = room.windows.first(where: { $0.id == id }) {
            return .window(win)
        } else if let op = room.openings.first(where: { $0.id == id }) {
            return .opening(op)
        } else if let wall = room.walls.first(where: { $0.id == id }) {
            return .wall(wall)
        }
        return nil
    }
    
    // MARK: - Plan Editing Mutations & Persistence
    
    private func deleteSelectedElement(id: UUID) {
        withAnimation {
            room.objects.removeAll { $0.id == id }
            room.doors.removeAll { $0.id == id }
            room.windows.removeAll { $0.id == id }
            room.openings.removeAll { $0.id == id }
            room.walls.removeAll { $0.id == id }
            selectedObjectId = nil
        }
        persistRoom()
    }
    
    private func rotateSelectedElement(id: UUID) {
        let rotMat90 = simd_float4x4(
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(-1, 0, 0, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        
        // 1. Furniture
        if let idx = room.objects.firstIndex(where: { $0.id == id }) {
            var obj = room.objects[idx]
            let angle: Float = .pi / 4.0 // 45 degrees for furniture
            let rotMat45 = simd_float4x4(
                SIMD4<Float>(cos(angle), 0, sin(angle), 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(-sin(angle), 0, cos(angle), 0),
                SIMD4<Float>(0, 0, 0, 1)
            )
            var newMat = simd_mul(obj.transform.matrix, rotMat45)
            newMat.columns.3 = obj.transform.matrix.columns.3
            obj.transform = TransformMatrix(newMat)
            room.objects[idx] = obj
            persistRoom()
            return
        }
        
        // 2. Door
        if let idx = room.doors.firstIndex(where: { $0.id == id }) {
            var door = room.doors[idx]
            var newMat = simd_mul(door.transform.matrix, rotMat90)
            newMat.columns.3 = door.transform.matrix.columns.3
            door.transform = TransformMatrix(newMat)
            room.doors[idx] = door
            persistRoom()
            return
        }
        
        // 3. Window
        if let idx = room.windows.firstIndex(where: { $0.id == id }) {
            var win = room.windows[idx]
            var newMat = simd_mul(win.transform.matrix, rotMat90)
            newMat.columns.3 = win.transform.matrix.columns.3
            win.transform = TransformMatrix(newMat)
            room.windows[idx] = win
            persistRoom()
            return
        }
        
        // 3b. Opening
        if let idx = room.openings.firstIndex(where: { $0.id == id }) {
            var op = room.openings[idx]
            var newMat = simd_mul(op.transform.matrix, rotMat90)
            newMat.columns.3 = op.transform.matrix.columns.3
            op.transform = TransformMatrix(newMat)
            room.openings[idx] = op
            persistRoom()
            return
        }
        
        // 4. Wall
        if let idx = room.walls.firstIndex(where: { $0.id == id }) {
            var wall = room.walls[idx]
            var newMat = simd_mul(wall.transform.matrix, rotMat90)
            newMat.columns.3 = wall.transform.matrix.columns.3
            wall.transform = TransformMatrix(newMat)
            room.walls[idx] = wall
            persistRoom()
            return
        }
    }
    
    private func nudgeSelectedElement(id: UUID, dx: Float, dz: Float) {
        if let idx = room.objects.firstIndex(where: { $0.id == id }) {
            var obj = room.objects[idx]
            var mat = obj.transform.matrix
            mat.columns.3.x += dx
            mat.columns.3.z += dz
            obj.transform = TransformMatrix(mat)
            room.objects[idx] = obj
            persistRoom()
            return
        }
        
        if let idx = room.doors.firstIndex(where: { $0.id == id }) {
            var door = room.doors[idx]
            var mat = door.transform.matrix
            mat.columns.3.x += dx
            mat.columns.3.z += dz
            door.transform = TransformMatrix(mat)
            room.doors[idx] = door
            persistRoom()
            return
        }
        
        if let idx = room.windows.firstIndex(where: { $0.id == id }) {
            var win = room.windows[idx]
            var mat = win.transform.matrix
            mat.columns.3.x += dx
            mat.columns.3.z += dz
            win.transform = TransformMatrix(mat)
            room.windows[idx] = win
            persistRoom()
            return
        }
        
        if let idx = room.openings.firstIndex(where: { $0.id == id }) {
            var op = room.openings[idx]
            var mat = op.transform.matrix
            mat.columns.3.x += dx
            mat.columns.3.z += dz
            op.transform = TransformMatrix(mat)
            room.openings[idx] = op
            persistRoom()
            return
        }
        
        if let idx = room.walls.firstIndex(where: { $0.id == id }) {
            var wall = room.walls[idx]
            var mat = wall.transform.matrix
            mat.columns.3.x += dx
            mat.columns.3.z += dz
            wall.transform = TransformMatrix(mat)
            room.walls[idx] = wall
            persistRoom()
            return
        }
    }
    
    private func nudgeSelectedObjectTo(id: UUID, targetPos: SIMD3<Float>) {
        if let idx = room.objects.firstIndex(where: { $0.id == id }) {
            var obj = room.objects[idx]
            var mat = obj.transform.matrix
            mat.columns.3.x = targetPos.x
            mat.columns.3.z = targetPos.z
            obj.transform = TransformMatrix(mat)
            room.objects[idx] = obj
            persistRoom()
            return
        }
        
        if let idx = room.doors.firstIndex(where: { $0.id == id }) {
            var door = room.doors[idx]
            var mat = door.transform.matrix
            mat.columns.3.x = targetPos.x
            mat.columns.3.z = targetPos.z
            door.transform = TransformMatrix(mat)
            room.doors[idx] = door
            persistRoom()
            return
        }
        
        if let idx = room.windows.firstIndex(where: { $0.id == id }) {
            var win = room.windows[idx]
            var mat = win.transform.matrix
            mat.columns.3.x = targetPos.x
            mat.columns.3.z = targetPos.z
            win.transform = TransformMatrix(mat)
            room.windows[idx] = win
            persistRoom()
            return
        }
        
        if let idx = room.openings.firstIndex(where: { $0.id == id }) {
            var op = room.openings[idx]
            var mat = op.transform.matrix
            mat.columns.3.x = targetPos.x
            mat.columns.3.z = targetPos.z
            op.transform = TransformMatrix(mat)
            room.openings[idx] = op
            persistRoom()
            return
        }
    }
    
    private func duplicateSelectedElement(id: UUID) {
        if let original = room.objects.first(where: { $0.id == id }) {
            var copy = original
            copy.id = UUID()
            copy.customName = "\(original.displayName) Copy"
            var mat = copy.transform.matrix
            mat.columns.3.x += 0.35
            mat.columns.3.z += 0.35
            copy.transform = TransformMatrix(mat)
            
            withAnimation {
                room.objects.append(copy)
                selectedObjectId = copy.id
            }
            persistRoom()
            return
        }
        
        if let original = room.doors.first(where: { $0.id == id }) {
            var copy = original
            copy.id = UUID()
            var mat = copy.transform.matrix
            mat.columns.3.x += 0.35
            mat.columns.3.z += 0.35
            copy.transform = TransformMatrix(mat)
            
            withAnimation {
                room.doors.append(copy)
                selectedObjectId = copy.id
            }
            persistRoom()
            return
        }
        
        if let original = room.windows.first(where: { $0.id == id }) {
            var copy = original
            copy.id = UUID()
            var mat = copy.transform.matrix
            mat.columns.3.x += 0.35
            mat.columns.3.z += 0.35
            copy.transform = TransformMatrix(mat)
            
            withAnimation {
                room.windows.append(copy)
                selectedObjectId = copy.id
            }
            persistRoom()
            return
        }
    }
    
    private func toggleSelectedElementState(id: UUID) {
        if let idx = room.doors.firstIndex(where: { $0.id == id }) {
            var door = room.doors[idx]
            door.isOpen.toggle()
            room.doors[idx] = door
            persistRoom()
        }
    }
    
    private func addNewDoor(width: Float, height: Float, isOpen: Bool) {
        let bounds = room.boundingBox
        let center = (bounds.min + bounds.max) / 2.0
        
        var mat = matrix_identity_float4x4
        mat.columns.3 = SIMD4<Float>(center.x, height / 2.0, center.z, 1.0)
        
        let newDoor = DoorSurface(
            id: UUID(),
            dimensions: SIMD3<Float>(width, height, 0.05),
            transform: mat,
            isOpen: isOpen
        )
        
        withAnimation {
            room.doors.append(newDoor)
            selectedObjectId = newDoor.id
        }
        persistRoom()
    }
    
    private func addNewWindow(width: Float, height: Float) {
        let bounds = room.boundingBox
        let center = (bounds.min + bounds.max) / 2.0
        
        var mat = matrix_identity_float4x4
        mat.columns.3 = SIMD4<Float>(center.x, 1.20, center.z, 1.0)
        
        let newWindow = WindowSurface(
            id: UUID(),
            dimensions: SIMD3<Float>(width, height, 0.08),
            transform: mat
        )
        
        withAnimation {
            room.windows.append(newWindow)
            selectedObjectId = newWindow.id
        }
        persistRoom()
    }
    
    private func addNewFurniture(template: FurnitureTemplate) {
        let bounds = room.boundingBox
        let center = (bounds.min + bounds.max) / 2.0
        
        var mat = matrix_identity_float4x4
        mat.columns.3 = SIMD4<Float>(center.x, template.dimensions.y / 2.0, center.z, 1.0)
        
        let newObj = FurnitureObject(
            id: UUID(),
            category: template.category,
            customName: template.name,
            dimensions: template.dimensions,
            transform: mat
        )
        
        withAnimation {
            room.objects.append(newObj)
            selectedObjectId = newObj.id
        }
        persistRoom()
    }
    
    private func persistRoom() {
        projectStore.saveRoom(room)
    }
    
    // MARK: - AR Quick Look
    
    private func launchARQuickLook() {
        isPreparingAR = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let url = try USDZExporter.export(room: room, style: maquetteStyle)
                DispatchQueue.main.async {
                    self.isPreparingAR = false
                    self.quickLookURL = url
                }
            } catch {
                DispatchQueue.main.async {
                    self.isPreparingAR = false
                    self.arErrorMessage = error.localizedDescription
                    self.showARErrorAlert = true
                }
            }
        }
    }
    
    // MARK: - Plan Import & Auto-Alignment
    
    private func handlePlanImport(from url: URL) {
        do {
            var imported = try PlanImporter.import(from: url)
            let autoTransform = PlanAutoMatcher.match(scan: room, plan: imported)
            imported.alignment = autoTransform
            withAnimation {
                self.room.importedPlan = imported
            }
            persistRoom()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showPlanMatchingSheet = true
            }
        } catch {
            self.importErrorMessage = error.localizedDescription
            self.showImportErrorAlert = true
        }
    }
}
