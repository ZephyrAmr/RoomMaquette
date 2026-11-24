import SwiftUI
import ARKit
import SceneKit
import simd

public struct RoomLocateMeView: View {
    @Environment(\.dismiss) private var dismiss
    public var room: MaquetteRoom
    
    @StateObject private var tracker = ARIndoorPositionTracker()
    @State private var minimapExpanded: Bool = false
    @State private var showingCalibrationAlert: Bool = false
    @State private var pendingCalibrationTarget: SIMD3<Float>? = nil
    
    public init(room: MaquetteRoom) {
        self.room = room
    }
    
    public var body: some View {
        ZStack {
            // 1. Live AR Camera Feed
            ARCameraFeedView(session: tracker.session)
                .ignoresSafeArea()
            
            // 2. Camera Crosshair & Horizon Guide
            VStack {
                Spacer()
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                        .frame(width: 80, height: 80)
                    
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .light))
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
            }
            
            // 3. Top Floating Status & Control Bar
            VStack {
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
                    
                    // Tracking Status & Coordinates
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(tracker.isTracking ? Color.green : Color.orange)
                                .frame(width: 8, height: 8)
                            Text(tracker.trackingStatusText)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.primary)
                        }
                        
                        if let pos = tracker.currentPosition, let head = tracker.currentHeading {
                            let deg = Int((head * 180.0 / .pi).truncatingRemainder(dividingBy: 360))
                            let headingNormalized = deg < 0 ? deg + 360 : deg
                            Text(String(format: "X: %+.2fm  Z: %+.2fm  (%03d°)", pos.x, pos.z, headingNormalized))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    
                    Spacer()
                    
                    // Calibrate / Reset Button
                    Menu {
                        Button {
                            // Reset origin to current camera position
                            let center = (room.boundingBox.min + room.boundingBox.max) / 2.0
                            tracker.calibrateCurrentPosition(to: center)
                        } label: {
                            Label("Align with Room Center", systemImage: "scope")
                        }
                        
                        Button {
                            tracker.resetCalibration()
                        } label: {
                            Label("Reset AR Origin", systemImage: "arrow.counterclockwise")
                        }
                    } label: {
                        Image(systemName: "location.north.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.blue)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(.horizontal)
                .padding(.top, 8)
                
                Spacer()
                
                // 4. Bottom Live 2D Minimap Drawer
                bottomMinimapDrawer
            }
        }
        .onAppear {
            tracker.start()
        }
        .onDisappear {
            tracker.stop()
        }
        .alert("Calibrate Position", isPresented: $showingCalibrationAlert) {
            Button("Yes, I am standing here") {
                if let target = pendingCalibrationTarget {
                    tracker.calibrateCurrentPosition(to: target)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Set your live camera location to the point you tapped on the 2D floor plan?")
        }
    }
    
    // MARK: - Bottom Minimap Drawer
    
    private var bottomMinimapDrawer: some View {
        VStack(spacing: 0) {
            // Drag Handle & Drawer Header
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.blue)
                    Text("Live 2D Room Minimap")
                        .font(.system(size: 13, weight: .bold))
                }
                
                Spacer()
                
                Text(tracker.isCalibrated ? "Calibrated" : "Tap plan to align")
                    .font(.caption2)
                    .foregroundColor(tracker.isCalibrated ? .green : .secondary)
                
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
            
            // 2D Floor Plan Canvas with Live Position Puck
            FloorPlan2DCanvas(
                room: room,
                showGrid: true,
                showDimensions: false,
                isMetric: true,
                selectedObjectId: nil,
                userPosition: tracker.currentPosition,
                userHeading: tracker.currentHeading,
                isInteractiveEditing: false,
                onTapPlanCoordinate: { tappedPoint in
                    pendingCalibrationTarget = tappedPoint
                    showingCalibrationAlert = true
                }
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
