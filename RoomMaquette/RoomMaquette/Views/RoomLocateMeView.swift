import SwiftUI
import ARKit
import SceneKit
import simd

public struct RoomLocateMeView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding public var room: MaquetteRoom
    public var onSaveRoom: (() -> Void)?
    
    @StateObject private var tracker = ARIndoorPositionTracker()
    @State private var minimapExpanded: Bool = false
    @State private var locateDisplayMode: FloorPlanDisplayMode
    
    public init(room: Binding<MaquetteRoom>, onSaveRoom: (() -> Void)? = nil) {
        self._room = room
        self.onSaveRoom = onSaveRoom
        self._locateDisplayMode = State(initialValue: room.wrappedValue.importedPlan != nil ? .importedBlueprint : .scannedPlan)
    }
    
    public var body: some View {
        ZStack {
            // 1. Live AR Camera Feed
            ARCameraFeedView(session: tracker.session)
                .ignoresSafeArea()
            
            // 2. Center LiDAR Crosshair & Target Distance Guide
            centerReticleOverlay
            
            // 3. Top Floating Status Bar + Discrepancy Pop-up + Bottom Minimap Drawer
            VStack(spacing: 10) {
                topStatusBar
                
                Spacer()
                
                if let discrepancy = tracker.activeDiscrepancy {
                    discrepancyPopupCard(discrepancy)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                bottomMinimapDrawer
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: tracker.activeDiscrepancy?.id)
        }
        .onAppear {
            tracker.start(with: room)
        }
        .onDisappear {
            tracker.stop()
        }
    }
    
    // MARK: - Discrepancy Pop-Up Card (Missing or New Room Object)
    
    private func isMissingKind(_ discrepancy: RoomDiscrepancy) -> Bool {
        if case .missingObject = discrepancy.kind { return true }
        return false
    }
    
    @ViewBuilder
    private func discrepancyPopupCard(_ discrepancy: RoomDiscrepancy) -> some View {
        let isMissing = isMissingKind(discrepancy)
        
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isMissing ? "exclamationmark.triangle.fill" : "plus.viewfinder")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(isMissing ? .orange : .blue)
                    .frame(width: 34, height: 34)
                    .background((isMissing ? Color.orange : Color.blue).opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(discrepancy.title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.primary)
                    Text(discrepancy.subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                
                Spacer()
                
                Button {
                    tracker.dismissDiscrepancy(discrepancy)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
            }
            
            HStack(spacing: 10) {
                Button {
                    handleDiscrepancyPrimaryAction(discrepancy)
                } label: {
                    Text(isMissing ? "Remove from Plan" : "Add to Plan")
                        .font(.system(size: 13, weight: .bold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(isMissing ? Color.orange : Color.blue, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.white)
                }
                
                Button {
                    tracker.dismissDiscrepancy(discrepancy)
                } label: {
                    Text(isMissing ? "Keep" : "Ignore")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.primary)
                }
            }
        }
        .padding(14)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke((isMissing ? Color.orange : Color.blue).opacity(0.35), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.22), radius: 14, y: 4)
        .padding(.horizontal, 12)
    }
    
    private func handleDiscrepancyPrimaryAction(_ discrepancy: RoomDiscrepancy) {
        switch discrepancy.kind {
        case .missingObject(let obj):
            room.objects.removeAll { $0.id == obj.id }
            room.modifiedAt = Date()
            onSaveRoom?()
            tracker.dismissDiscrepancy(discrepancy)
            tracker.updateRoom(room)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            
        case .newObject(let roomPos, let dims, let suggestedName, let category):
            var mat = matrix_identity_float4x4
            mat.columns.3 = SIMD4<Float>(roomPos.x, roomPos.y, roomPos.z, 1.0)
            let newObj = FurnitureObject(
                id: UUID(),
                category: category,
                customName: suggestedName,
                dimensions: dims,
                transform: mat
            )
            room.objects.append(newObj)
            room.modifiedAt = Date()
            onSaveRoom?()
            tracker.dismissDiscrepancy(discrepancy)
            tracker.updateRoom(room)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
    
    // MARK: - Center Reticle & Distance Guide
    
    private var centerReticleOverlay: some View {
        VStack(spacing: 8) {
            Spacer()
            
            ZStack {
                Circle()
                    .stroke(
                        tracker.isAutoLocalized ? Color.green.opacity(0.8) : Color.white.opacity(0.45),
                        lineWidth: tracker.isAutoLocalized ? 2.5 : 1.5
                    )
                    .frame(width: 72, height: 72)
                    .scaleEffect(tracker.isAutoLocalized ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: tracker.isAutoLocalized)
                
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .light))
                    .foregroundColor(tracker.isAutoLocalized ? .green : .white.opacity(0.8))
                
                Circle()
                    .fill(tracker.isAutoLocalized ? Color.green : Color.white)
                    .frame(width: 4, height: 4)
            }
            
            if let dist = tracker.targetDistanceMeters {
                HStack(spacing: 4) {
                    Image(systemName: "ruler")
                        .font(.system(size: 10, weight: .semibold))
                    Text(String(format: "%.2f m", dist))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundColor(.white)
                .shadow(radius: 4)
                .transition(.opacity)
            }
            
            Spacer()
        }
    }
    
    // MARK: - Top Floating Status Bar
    
    private var topStatusBar: some View {
        HStack(spacing: 12) {
            Button {
                tracker.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
                    .foregroundColor(.primary)
            }
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tracker.isAutoLocalized ? Color.green : (tracker.isTracking ? Color.orange : Color.red))
                        .frame(width: 9, height: 9)
                    
                    Text(
                        tracker.isAutoLocalized
                        ? (tracker.isLocatingOnImportedPlan ? "Localized on Plan" : "Localized in Room")
                        : "Walls: \(tracker.observedWallCount) • Landmarks: \(tracker.observedLandmarkCount)"
                    )
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.primary)
                }
                
                Text(tracker.trackingStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            
            Spacer()
            
            Button {
                tracker.relocalize()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
    }
    
    // MARK: - Bottom Minimap Drawer
    
    private var bottomMinimapDrawer: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 13))
                        .foregroundColor(tracker.isAutoLocalized ? .blue : .orange)
                    Text(locateDisplayMode == .importedBlueprint ? (room.importedPlan?.name ?? "Blueprint") : "Live 2D Room Position")
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)
                }
                
                Spacer()
                
                if room.importedPlan != nil {
                    Picker("Map View", selection: $locateDisplayMode) {
                        Text("Blueprint").tag(FloorPlanDisplayMode.importedBlueprint)
                        Text("Scan").tag(FloorPlanDisplayMode.scannedPlan)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 160)
                }
                
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        minimapExpanded.toggle()
                    }
                } label: {
                    Image(systemName: minimapExpanded ? "chevron.down.circle.fill" : "chevron.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            
            ZStack(alignment: .bottomLeading) {
                FloorPlan2DCanvas(
                    room: room,
                    importedPlan: room.importedPlan,
                    displayMode: locateDisplayMode,
                    showGrid: true,
                    showDimensions: false,
                    isMetric: true,
                    selectedObjectId: nil,
                    userPosition: tracker.currentPosition,
                    userHeading: tracker.currentHeading,
                    userPositionIsInPlanSpace: tracker.isLocatingOnImportedPlan,
                    userHintPosition: tracker.userHintPosition,
                    isInteractiveEditing: false,
                    onTapPlanCoordinate: { pt in
                        tracker.setRegionHint(SIMD2<Float>(pt.x, pt.z))
                    }
                )
                
                if !tracker.isAutoLocalized {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(tracker.userHintPosition == nil
                             ? "Dot hidden until locked • Tap minimap to hint room"
                             : "Room hint set • Locating nearby...")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.primary)
                        if tracker.userHintPosition != nil {
                            Button("Clear") {
                                tracker.clearRegionHint()
                            }
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundColor(.purple)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(10)
                }
            }
            .frame(height: minimapExpanded ? 380 : 220)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
        .shadow(color: Color.black.opacity(0.18), radius: 16, y: -4)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - AR Camera Viewport

struct ARCameraFeedView: UIViewRepresentable {
    var session: ARSession
    
    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.autoenablesDefaultLighting = false
        view.automaticallyUpdatesLighting = true
        return view
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
