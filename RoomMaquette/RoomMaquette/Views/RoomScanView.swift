import SwiftUI
import RoomPlan

public struct RoomScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var projectStore: ProjectStore
    
    @StateObject private var captureManager = RoomCaptureManager()
    @State private var showingUnsupportedAlert = false
    @State private var scanFinished = false
    @State private var newlyCreatedRoom: MaquetteRoom? = nil
    
    public init() {}
    
    public var body: some View {
        ZStack {
            if #available(iOS 16.0, *), LiDARDetector.isLiDARSupported {
                // Live Apple RoomPlan Camera Feed
                RoomCaptureViewContainer(captureManager: captureManager)
                    .ignoresSafeArea()
            } else {
                // Simulator / Non-LiDAR Fallback View
                simulatorFallbackView
            }
            
            // HUD Overlay Controls
            VStack {
                // Top Bar
                HStack {
                    Button("Cancel") {
                        if #available(iOS 16.0, *) {
                            captureManager.cancelCapture()
                        }
                        dismiss()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundColor(.primary)
                    
                    Spacer()
                    
                    // Scanning Duration Indicator
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text(formatTime(captureManager.scanDurationSeconds))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .padding()
                
                Spacer()
                
                // Live Stats HUD
                HStack(spacing: 16) {
                    statPill(label: "Walls", count: captureManager.wallCount, icon: "square.split.diagonal.2x2")
                    statPill(label: "Doors", count: captureManager.doorCount, icon: "door.left.hand.open")
                    statPill(label: "Windows", count: captureManager.windowCount, icon: "window.vertical.closed")
                    statPill(label: "Objects", count: captureManager.objectCount, icon: "sofa.fill")
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
                
                // Bottom Action Button
                VStack(spacing: 8) {
                    Button {
                        finishScanning()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Finish Scan & Generate Maquette")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundColor(.white)
                    }
                    
                    Text("Point iPhone at walls, corners, doors, and furniture")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
        .onAppear {
            if #available(iOS 16.0, *), LiDARDetector.isLiDARSupported {
                captureManager.startCapture()
            } else {
                showingUnsupportedAlert = true
            }
        }
        .alert("LiDAR Scanner Required", isPresented: $showingUnsupportedAlert) {
            Button("Use Sample Demo Room") {
                let demo = SampleRooms.modernStudio
                var newDemo = demo
                newDemo.id = UUID()
                newDemo.name = "LiDAR Demo Maquette"
                projectStore.saveRoom(newDemo)
                projectStore.selectedRoomId = newDemo.id
                dismiss()
            }
            Button("Dismiss", role: .cancel) {
                dismiss()
            }
        } message: {
            Text("RoomPlan 3D room capture requires an iPhone Pro (12 Pro or newer) or iPad Pro with LiDAR scanner.\n\nYou can still explore all 3D maquette viewing, 2D floor plans, and export formats using sample rooms.")
        }
    }
    
    private var simulatorFallbackView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "camera.metering.matrix")
                    .font(.system(size: 64))
                    .foregroundColor(.blue)
                
                Text("LiDAR Room Scanner Simulation")
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                
                Text(LiDARDetector.hardwareStatusMessage)
                    .font(.subheadline)
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                Button("Simulate Completed Room Capture") {
                    finishScanning()
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 8)
            }
        }
    }
    
    @ViewBuilder
    private func statPill(label: String, count: Int, icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.blue)
            Text("\(count)")
                .font(.system(size: 15, weight: .bold))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    
    private func finishScanning() {
        if #available(iOS 16.0, *), LiDARDetector.isLiDARSupported {
            captureManager.stopCapture { room in
                if let room = room {
                    projectStore.saveRoom(room)
                    projectStore.selectedRoomId = room.id
                }
                dismiss()
            }
        } else {
            // Simulator or Demo Mode
            let newRoom = SampleRooms.modernStudio
            var fresh = newRoom
            fresh.id = UUID()
            fresh.name = "Scanned Room \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
            projectStore.saveRoom(fresh)
            projectStore.selectedRoomId = fresh.id
            dismiss()
        }
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }
}
