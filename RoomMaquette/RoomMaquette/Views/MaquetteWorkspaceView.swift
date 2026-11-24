import SwiftUI
import QuickLook

public struct MaquetteWorkspaceView: View {
    public var room: MaquetteRoom
    @EnvironmentObject private var projectStore: ProjectStore
    
    @State private var selectedTab: Int = 0 // 0: 3D Maquette, 1: 2D Plan, 2: Specs
    @State private var maquetteStyle: MaquetteStyle = .architecturalClay
    @State private var showCeiling: Bool = false
    @State private var show3DDimensions: Bool = false
    @State private var showExportSheet: Bool = false
    @State private var quickLookURL: URL? = nil
    @State private var selectedObjectInfo: String? = nil
    @State private var isPreparingAR: Bool = false
    @State private var arErrorMessage: String? = nil
    @State private var showARErrorAlert: Bool = false
    
    public init(room: MaquetteRoom) {
        self.room = room
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
            
            // Content Area
            ZStack {
                switch selectedTab {
                case 0:
                    maquette3DContainer
                case 1:
                    FloorPlanTabView(room: room)
                case 2:
                    RoomMetricsView(room: room)
                default:
                    EmptyView()
                }
            }
        }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheetView(room: room)
        }
        .quickLookPreview($quickLookURL)
        .alert("Unable to Start AR", isPresented: $showARErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(arErrorMessage ?? "Could not prepare the 3D model for Augmented Reality preview.")
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
                onSelectObject: { name in
                    selectedObjectInfo = name
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
}
