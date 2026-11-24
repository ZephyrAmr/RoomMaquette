import SwiftUI
import simd

public struct FloorPlanTabView: View {
    public var room: MaquetteRoom
    public var selectedObjectId: UUID? = nil
    public var onSelectObject: ((UUID?) -> Void)? = nil
    public var onMoveObject: ((UUID, SIMD3<Float>) -> Void)? = nil
    public var onImportPlan: (() -> Void)? = nil
    public var onAlignPlan: (() -> Void)? = nil
    
    @State private var displayMode: FloorPlanDisplayMode = .scannedPlan
    @State private var showGrid: Bool = true
    @State private var showDimensions: Bool = true
    @State private var isMetric: Bool = true
    
    public init(
        room: MaquetteRoom,
        selectedObjectId: UUID? = nil,
        onSelectObject: ((UUID?) -> Void)? = nil,
        onMoveObject: ((UUID, SIMD3<Float>) -> Void)? = nil,
        onImportPlan: (() -> Void)? = nil,
        onAlignPlan: (() -> Void)? = nil
    ) {
        self.room = room
        self.selectedObjectId = selectedObjectId
        self.onSelectObject = onSelectObject
        self.onMoveObject = onMoveObject
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
                onSelectObject: onSelectObject,
                onMoveObject: onMoveObject
            )
            
            // Top Floating Plan Selector / Import Bar
            VStack {
                HStack(spacing: 8) {
                    if let plan = room.importedPlan {
                        Picker("Plan Mode", selection: $displayMode) {
                            Text("Scan").tag(FloorPlanDisplayMode.scannedPlan)
                            Text("Blueprint").tag(FloorPlanDisplayMode.importedBlueprint)
                            Text("Composite").tag(FloorPlanDisplayMode.compositeOverlay)
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                        
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
                
                Spacer()
                
                // Floating Toolbar at the bottom
                HStack(spacing: 12) {
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
                        Text(isMetric ? "METER" : "FEET")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color(UIColor.secondarySystemGroupedBackground))
                            .foregroundColor(.primary)
                            .clipShape(Capsule())
                            .shadow(radius: 2)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}
