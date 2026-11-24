import SwiftUI
import RoomPlan

public struct RoomScanView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var projectStore: ProjectStore
    
    @StateObject private var captureManager = RoomCaptureManager()
    @State private var showingUnsupportedAlert = false
    @State private var showingNoSurfacesAlert = false
    @State private var isProcessing = false
    
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
                
                // Live Stats HUD (Real-time surface counts)
                HStack(spacing: 12) {
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
                        HStack(spacing: 8) {
                            if isProcessing {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                            }
                            Text(isProcessing ? "Processing Maquette..." : "Finish Scan & Generate Maquette")
                                .fontWeight(.bold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(isProcessing ? Color.gray : Color.blue, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundColor(.white)
                    }
                    .disabled(isProcessing)
                    
                    Text("Point iPhone camera slowly at walls, corners, doors, and furniture")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.8))
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            
            // Full-screen Processing Overlay
            if isProcessing {
                ZStack {
                    Color.black.opacity(0.65).ignoresSafeArea()
                    VStack(spacing: 18) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.8)
                        
                        Text("Generating 3D Maquette...")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        Text("Reconstructing LiDAR geometry, surface boundaries & furniture")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                    }
                    .padding(30)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                    .shadow(radius: 20)
                }
                .transition(.opacity)
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
        .alert("No Room Surfaces Detected", isPresented: $showingNoSurfacesAlert) {
            Button("Keep Scanning", role: .cancel) {
                isProcessing = false
            }
            Button("Use Demo Room") {
                let demo = SampleRooms.modernStudio
                var newDemo = demo
                newDemo.id = UUID()
                newDemo.name = "Sample Studio Maquette"
                projectStore.saveRoom(newDemo)
                projectStore.selectedRoomId = newDemo.id
                dismiss()
            }
        } message: {
            Text("No walls or furniture were detected yet. Make sure you point your iPhone camera at walls, corners, and floor edges before finishing.")
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
            withAnimation {
                isProcessing = true
            }
            captureManager.stopCapture { room in
                DispatchQueue.main.async {
                    self.isProcessing = false
                    if let room = room, (!room.walls.isEmpty || !room.objects.isEmpty) {
                        self.projectStore.saveRoom(room)
                        self.projectStore.selectedRoomId = room.id
                        self.dismiss()
                    } else {
                        self.showingNoSurfacesAlert = true
                    }
                }
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
