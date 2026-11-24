import SwiftUI
import simd

public struct FloorPlanTabView: View {
    public var room: MaquetteRoom
    public var selectedObjectId: UUID? = nil
    public var onSelectObject: ((UUID?) -> Void)? = nil
    public var onMoveObject: ((UUID, SIMD3<Float>) -> Void)? = nil
    
    @State private var showGrid: Bool = true
    @State private var showDimensions: Bool = true
    @State private var isMetric: Bool = true
    
    public init(
        room: MaquetteRoom,
        selectedObjectId: UUID? = nil,
        onSelectObject: ((UUID?) -> Void)? = nil,
        onMoveObject: ((UUID, SIMD3<Float>) -> Void)? = nil
    ) {
        self.room = room
        self.selectedObjectId = selectedObjectId
        self.onSelectObject = onSelectObject
        self.onMoveObject = onMoveObject
    }
    
    public var body: some View {
        ZStack {
            FloorPlan2DCanvas(
                room: room,
                showGrid: showGrid,
                showDimensions: showDimensions,
                isMetric: isMetric,
                selectedObjectId: selectedObjectId,
                onSelectObject: onSelectObject,
                onMoveObject: onMoveObject
            )
            
            // Floating Toolbar at the bottom
            VStack {
                Spacer()
                
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
