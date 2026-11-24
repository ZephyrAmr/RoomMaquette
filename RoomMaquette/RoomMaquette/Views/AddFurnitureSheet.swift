import SwiftUI
import simd

public struct FurnitureTemplate: Identifiable {
    public var id = UUID()
    public var name: String
    public var category: ObjectCategory
    public var dimensions: SIMD3<Float> // width, height, depth
    public var group: String
}

public struct AddFurnitureSheet: View {
    @Environment(\.dismiss) private var dismiss
    public var onSelectTemplate: (FurnitureTemplate) -> Void
    
    private let templates: [FurnitureTemplate] = [
        // Living Room
        FurnitureTemplate(name: "3-Seat Sofa", category: .sofa, dimensions: SIMD3<Float>(2.10, 0.85, 0.90), group: "Living Room"),
        FurnitureTemplate(name: "Armchair", category: .chair, dimensions: SIMD3<Float>(0.85, 0.80, 0.85), group: "Living Room"),
        FurnitureTemplate(name: "Coffee Table", category: .table, dimensions: SIMD3<Float>(1.20, 0.45, 0.60), group: "Living Room"),
        FurnitureTemplate(name: "Media TV Unit", category: .television, dimensions: SIMD3<Float>(1.60, 0.55, 0.45), group: "Living Room"),
        FurnitureTemplate(name: "Fiddle Leaf Plant", category: .plant, dimensions: SIMD3<Float>(0.50, 1.20, 0.50), group: "Living Room"),
        
        // Bedroom
        FurnitureTemplate(name: "King Bed", category: .bed, dimensions: SIMD3<Float>(1.95, 1.05, 2.05), group: "Bedroom"),
        FurnitureTemplate(name: "Queen Bed", category: .bed, dimensions: SIMD3<Float>(1.60, 1.05, 2.05), group: "Bedroom"),
        FurnitureTemplate(name: "Wardrobe / Closet", category: .storage, dimensions: SIMD3<Float>(1.80, 2.10, 0.60), group: "Bedroom"),
        FurnitureTemplate(name: "Nightstand", category: .table, dimensions: SIMD3<Float>(0.50, 0.55, 0.45), group: "Bedroom"),
        
        // Workspace
        FurnitureTemplate(name: "Executive Desk", category: .desk, dimensions: SIMD3<Float>(1.60, 0.75, 0.80), group: "Workspace"),
        FurnitureTemplate(name: "Ergonomic Chair", category: .chair, dimensions: SIMD3<Float>(0.65, 0.95, 0.65), group: "Workspace"),
        FurnitureTemplate(name: "Bookshelf", category: .storage, dimensions: SIMD3<Float>(1.00, 1.80, 0.35), group: "Workspace"),
        
        // Dining & Kitchen
        FurnitureTemplate(name: "Dining Table (6-Seat)", category: .table, dimensions: SIMD3<Float>(1.80, 0.76, 0.90), group: "Dining & Kitchen"),
        FurnitureTemplate(name: "Dining Chair", category: .chair, dimensions: SIMD3<Float>(0.50, 0.85, 0.50), group: "Dining & Kitchen"),
        FurnitureTemplate(name: "Refrigerator", category: .refrigerator, dimensions: SIMD3<Float>(0.90, 1.80, 0.80), group: "Dining & Kitchen"),
        FurnitureTemplate(name: "Stove & Range", category: .stove, dimensions: SIMD3<Float>(0.75, 0.90, 0.65), group: "Dining & Kitchen"),
        FurnitureTemplate(name: "Kitchen Sink Island", category: .sink, dimensions: SIMD3<Float>(1.20, 0.90, 0.65), group: "Dining & Kitchen"),
        
        // Bathroom
        FurnitureTemplate(name: "Bathtub", category: .bathtub, dimensions: SIMD3<Float>(1.70, 0.60, 0.75), group: "Bathroom"),
        FurnitureTemplate(name: "Toilet", category: .toilet, dimensions: SIMD3<Float>(0.50, 0.75, 0.70), group: "Bathroom"),
        FurnitureTemplate(name: "Bathroom Vanity", category: .sink, dimensions: SIMD3<Float>(0.90, 0.85, 0.50), group: "Bathroom"),
    ]
    
    private var groups: [String] {
        Array(Set(templates.map { $0.group })).sorted()
    }
    
    public init(onSelectTemplate: @escaping (FurnitureTemplate) -> Void) {
        self.onSelectTemplate = onSelectTemplate
    }
    
    public var body: some View {
        NavigationStack {
            List {
                ForEach(groups, id: \.self) { group in
                    Section(header: Text(group).fontWeight(.semibold)) {
                        ForEach(templates.filter { $0.group == group }) { item in
                            Button {
                                onSelectTemplate(item)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(item.category.accentColor.opacity(0.15))
                                            .frame(width: 44, height: 44)
                                        Image(systemName: item.category.systemIcon)
                                            .font(.system(size: 20))
                                            .foregroundColor(item.category.accentColor)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.name)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Text(String(format: "%.2fm × %.2fm  •  H: %.2fm", item.dimensions.x, item.dimensions.z, item.dimensions.y))
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(.blue)
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Add Furniture Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
