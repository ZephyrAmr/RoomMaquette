import SwiftUI
import ARKit
import SceneKit
import simd

public struct RoomLocateMeView: View {
    @Environment(\.dismiss) private var dismiss
    public var room: MaquetteRoom
    
    @StateObject private var tracker = ARIndoorPositionTracker()
    @State private var minimapExpanded: Bool = false
    @State private var locateDisplayMode: FloorPlanDisplayMode
    
    public init(room: MaquetteRoom) {
        self.room = room
        // If room has an imported blueprint, default to locating on the blueprint!
        self._locateDisplayMode = State(initialValue: room.importedPlan != nil ? .importedBlueprint : .scannedPlan)
    }
    
    public var body: some View {
        ZStack {
            // 1. Live AR Camera Feed
            ARCameraFeedView(session: tracker.session)
                .ignoresSafeArea()
            
            // 2. Center LiDAR Crosshair & Target Distance Guide
            centerReticleOverlay
            
            // 3. Top Floating Status & Control Bar
            VStack {
                topStatusBar
                
                Spacer()
                
                // 4. Bottom Live 2D Minimap Drawer
                bottomMinimapDrawer
            }
        }
        .onAppear {
            tracker.start(with: room)
        }
        .onDisappear {
            tracker.stop()
        }
    }
    
    // MARK: - Center Reticle & Distance Guide
    
    private var centerReticleOverlay: some View {
        VStack(spacing: 8) {
            Spacer()
            
            ZStack {
                // Outer tracking ring
                Circle()
                    .stroke(
                        tracker.isAutoLocalized ? Color.green.opacity(0.8) : Color.white.opacity(0.4),
                        lineWidth: tracker.isAutoLocalized ? 2.5 : 1.5
                    )
                    .frame(width: 72, height: 72)
                    .scaleEffect(tracker.isAutoLocalized ? 1.05 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: tracker.isAutoLocalized)
                
                // Crosshair tick marks
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .light))
                    .foregroundColor(tracker.isAutoLocalized ? .green : .white.opacity(0.8))
                
                // Inner center dot
                Circle()
                    .fill(tracker.isAutoLocalized ? Color.green : Color.white)
                    .frame(width: 4, height: 4)
            }
            
            // Live Distance Pill
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
            // Dismiss Button
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
            
            // Auto-Localization Status & Live Coordinates
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tracker.isAutoLocalized ? Color.green : (tracker.isTracking ? Color.orange : Color.red))
                        .frame(width: 9, height: 9)
                    
                    Text(tracker.isAutoLocalized ? (tracker.isLocatingOnImportedPlan ? "Localized on Plan" : "Auto-Localized") : (tracker.isLocatingOnImportedPlan ? "Scanning Walls (\(tracker.observedWallCount))..." : "Scanning Walls (\(tracker.observedWallCount))..."))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                }
                
                Text(tracker.trackingStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            
            Spacer()
            
            // Relocalize / Refresh Button
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
            // Drag Handle & Drawer Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.blue)
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
            
            // 2D Floor Plan Canvas with Live Position Puck and Directional Flashlight Beam
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
                isInteractiveEditing: false
            )
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
