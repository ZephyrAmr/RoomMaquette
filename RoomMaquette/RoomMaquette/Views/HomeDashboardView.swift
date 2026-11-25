import SwiftUI

public struct HomeDashboardView: View {
    @EnvironmentObject private var projectStore: ProjectStore
    @State private var showingScanSheet = false
    @State private var showingScanImporter = false
    @State private var showingNewRoomAlert = false
    @State private var newRoomName = ""
    @State private var importErrorMessage: String? = nil
    @State private var showingImportErrorAlert = false
    @State private var importedRoomToOpen: MaquetteRoom? = nil
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    
                    // Hardware Status Banner
                    hardwareBanner
                    
                    // Quick Action Hero Banner
                    scanCTASection
                    
                    // Import Existing Scan CTA
                    importScanButton
                    
                    // Projects Section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("SCANNED ROOMS & MAQUETTES")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(projectStore.rooms.count) Projects")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        
                        LazyVStack(spacing: 12) {
                            ForEach(projectStore.rooms) { room in
                                NavigationLink(destination: MaquetteWorkspaceView(room: room)) {
                                    roomCard(room: room)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        projectStore.duplicateRoom(room)
                                    } label: {
                                        Label("Duplicate", systemImage: "doc.on.doc")
                                    }
                                    
                                    Button(role: .destructive) {
                                        projectStore.deleteRoom(id: room.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("RoomMaquette")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingScanSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                    }
                }
                
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            showingScanImporter = true
                        } label: {
                            Label("Import Scan or Plan (USDZ, IFC, Image, PDF, SVG)", systemImage: "square.and.arrow.down")
                        }
                        
                        Divider()
                        
                        Button {
                            var studio = SampleRooms.modernStudio
                            studio.id = UUID()
                            studio.name = "Modern Studio #\(projectStore.rooms.count + 1)"
                            projectStore.saveRoom(studio)
                        } label: {
                            Label("Add Studio Apartment", systemImage: "bed.double")
                        }
                        
                        Button {
                            var office = SampleRooms.executiveOffice
                            office.id = UUID()
                            office.name = "Executive Office #\(projectStore.rooms.count + 1)"
                            projectStore.saveRoom(office)
                        } label: {
                            Label("Add Executive Boardroom", systemImage: "building.2")
                        }
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showingScanSheet) {
                RoomScanView()
                    .environmentObject(projectStore)
            }
            .fileImporter(
                isPresented: $showingScanImporter,
                allowedContentTypes: [.item, .data, .json, .image, .pdf]
            ) { result in
                switch result {
                case .success(let url):
                    handleScanImport(from: url)
                case .failure(let error):
                    importErrorMessage = error.localizedDescription
                    showingImportErrorAlert = true
                }
            }
            .alert("Import Error", isPresented: $showingImportErrorAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage ?? "Failed to import scan file.")
            }
        }
    }
    
    // MARK: - Hardware Banner
    private var hardwareBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: LiDARDetector.isLiDARSupported ? "sensor.tag.radiowaves.forward.fill" : "info.circle.fill")
                .foregroundColor(LiDARDetector.isLiDARSupported ? .green : .orange)
                .font(.system(size: 18))
            
            VStack(alignment: .leading, spacing: 2) {
                Text(LiDARDetector.isLiDARSupported ? "iPhone Pro LiDAR Active" : "LiDAR Emulation Active")
                    .font(.footnote)
                    .fontWeight(.bold)
                Text(LiDARDetector.hardwareStatusMessage)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding(12)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
    
    // MARK: - Scan CTA Hero
    private var scanCTASection: some View {
        Button {
            showingScanSheet = true
        } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 54, height: 54)
                    Image(systemName: "camera.viewfinder")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start LiDAR Room Scan")
                        .font(.headline)
                        .foregroundColor(.primary)
                    Text("Capture walls, doors, windows & furniture into a 3D maquette")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.04), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
    
    // MARK: - Room Card
    @ViewBuilder
    private func roomCard(room: MaquetteRoom) -> some View {
        HStack(spacing: 14) {
            // 3D Isometric Preview Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 64, height: 64)
                
                Image(systemName: "cube.transparent.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.blue)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(room.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text("\(room.formattedAreaMetric)  •  \(room.formattedAreaImperial)")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
                
                HStack(spacing: 8) {
                    Label("\(room.walls.count)w", systemImage: "square.split.diagonal.2x2")
                    Label("\(room.doors.count)d", systemImage: "door.left.hand.open")
                    Label("\(room.windows.count)g", systemImage: "window.vertical.closed")
                    Label("\(room.objects.count) obj", systemImage: "sofa.fill")
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Text(DateFormatter.localizedString(from: room.modifiedAt, dateStyle: .short, timeStyle: .none))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: Color.black.opacity(0.03), radius: 4, y: 2)
    }
    
    // MARK: - Import Scan Button
    private var importScanButton: some View {
        Button {
            showingScanImporter = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.purple.opacity(0.12))
                        .frame(width: 44, height: 44)
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.purple)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Scan or Floor Plan")
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                    Text("Import USDZ, IFC, JSON, OBJ scans, or PNG/PDF/SVG plans")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
    }
    
    private func handleScanImport(from url: URL) {
        do {
            let room = try ScanImporter.importScan(from: url)
            projectStore.saveRoom(room)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            importErrorMessage = error.localizedDescription
            showingImportErrorAlert = true
        }
    }
}
