import SwiftUI
import simd

public enum ElementCategoryTab: String, CaseIterable, Identifiable {
    case doors = "Doors"
    case windows = "Windows"
    case furniture = "Furniture"
    
    public var id: String { rawValue }
    
    public var icon: String {
        switch self {
        case .doors: return "door.left.hand.open"
        case .windows: return "window.vertical.closed"
        case .furniture: return "sofa.fill"
        }
    }
}

public struct DoorTemplate: Identifiable {
    public var id = UUID()
    public var name: String
    public var width: Float // in meters
    public var height: Float
    public var icon: String
    public var description: String
    public var isOpen: Bool
}

public struct WindowTemplate: Identifiable {
    public var id = UUID()
    public var name: String
    public var width: Float // in meters
    public var height: Float
    public var icon: String
    public var description: String
}

public struct AddArchitecturalElementSheet: View {
    @Environment(\.dismiss) private var dismiss
    
    public var onAddDoor: ((Float, Float, Bool) -> Void)?
    public var onAddWindow: ((Float, Float) -> Void)?
    public var onAddFurniture: ((FurnitureTemplate) -> Void)?
    
    @State private var selectedTab: ElementCategoryTab = .doors
    @State private var searchText = ""
    
    public static let standardDoors: [DoorTemplate] = [
        DoorTemplate(name: "Standard Interior Door", width: 0.80, height: 2.10, icon: "door.left.hand.open", description: "0.80m × 2.10m • Standard residential interior door", isOpen: true),
        DoorTemplate(name: "Wide Entrance Door", width: 0.95, height: 2.10, icon: "door.left.hand.closed", description: "0.95m × 2.10m • Front door or accessibility entrance", isOpen: true),
        DoorTemplate(name: "Double French Doors", width: 1.60, height: 2.10, icon: "door.sliding.left.hand.closed", description: "1.60m × 2.10m • Dual leaf patio or terrace doors", isOpen: true),
        DoorTemplate(name: "Pocket / Sliding Door", width: 0.80, height: 2.10, icon: "door.sliding.left.hand.open", description: "0.80m × 2.10m • Space-saving in-wall sliding door", isOpen: true),
        DoorTemplate(name: "Cased Archway / Opening", width: 0.90, height: 2.15, icon: "rectangle.dashed", description: "0.90m × 2.15m • Wall opening without door leaf", isOpen: true)
    ]
    
    public static let standardWindows: [WindowTemplate] = [
        WindowTemplate(name: "Standard Casement Window", width: 1.00, height: 1.20, icon: "window.vertical.closed", description: "1.00m × 1.20m • Classic bedroom or living window"),
        WindowTemplate(name: "Large Picture Window", width: 1.80, height: 1.40, icon: "window.horizontal.closed", description: "1.80m × 1.40m • Expansive living room view window"),
        WindowTemplate(name: "Floor-to-Ceiling French Window", width: 1.20, height: 2.20, icon: "window.ceiling.closed", description: "1.20m × 2.20m • Full height panoramic glazing"),
        WindowTemplate(name: "Compact Bathroom Window", width: 0.60, height: 0.60, icon: "square.split.2x2", description: "0.60m × 0.60m • High ventilation window")
    ]
    
    public init(
        onAddDoor: ((Float, Float, Bool) -> Void)? = nil,
        onAddWindow: ((Float, Float) -> Void)? = nil,
        onAddFurniture: ((FurnitureTemplate) -> Void)? = nil
    ) {
        self.onAddDoor = onAddDoor
        self.onAddWindow = onAddWindow
        self.onAddFurniture = onAddFurniture
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Segmented Tab Picker
                Picker("Category", selection: $selectedTab) {
                    ForEach(ElementCategoryTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                
                ScrollView {
                    VStack(spacing: 16) {
                        switch selectedTab {
                        case .doors:
                            doorsSection
                        case .windows:
                            windowsSection
                        case .furniture:
                            furnitureSection
                        }
                    }
                    .padding()
                }
            }
            .background(Color(UIColor.systemGroupedBackground))
            .navigationTitle("Add Architectural Element")
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
    
    // MARK: - Doors Section
    
    private var doorsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DOOR PRESETS")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            ForEach(Self.standardDoors) { door in
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onAddDoor?(door.width, door.height, door.isOpen)
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.blue.opacity(0.12))
                                .frame(width: 48, height: 48)
                            Image(systemName: door.icon)
                                .font(.system(size: 22))
                                .foregroundColor(.blue)
                        }
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text(door.name)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            Text(door.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.blue)
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Windows Section
    
    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WINDOW PRESETS")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            ForEach(Self.standardWindows) { win in
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onAddWindow?(win.width, win.height)
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.cyan.opacity(0.14))
                                .frame(width: 48, height: 48)
                            Image(systemName: win.icon)
                                .font(.system(size: 22))
                                .foregroundColor(.cyan)
                        }
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text(win.name)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            Text(win.description)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.cyan)
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Furniture Section
    
    private var furnitureSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FURNITURE & FIXTURES")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
            
            ForEach(FurnitureTemplate.defaultTemplates) { template in
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onAddFurniture?(template)
                    dismiss()
                } label: {
                    HStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(template.category.accentColor.opacity(0.14))
                                .frame(width: 48, height: 48)
                            Image(systemName: template.category.systemIcon)
                                .font(.system(size: 22))
                                .foregroundColor(template.category.accentColor)
                        }
                        
                        VStack(alignment: .leading, spacing: 3) {
                            Text(template.name)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                            Text(String(format: "%.2fm (W) × %.2fm (D) • H: %.2fm", template.dimensions.x, template.dimensions.z, template.dimensions.y))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(template.category.accentColor)
                    }
                    .padding(12)
                    .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
