import SwiftUI
import simd

public enum InspectableElement {
    case furniture(FurnitureObject)
    case door(DoorSurface)
    case window(WindowSurface)
    case wall(WallSurface)
    
    public var id: UUID {
        switch self {
        case .furniture(let obj): return obj.id
        case .door(let d): return d.id
        case .window(let w): return w.id
        case .wall(let wall): return wall.id
        }
    }
    
    public var title: String {
        switch self {
        case .furniture(let obj): return obj.displayName
        case .door: return "Architectural Door"
        case .window: return "Architectural Window"
        case .wall(let wall): return wall.displayName
        }
    }
    
    public var subtitle: String {
        switch self {
        case .furniture(let obj):
            return String(format: "%.2fm × %.2fm • H: %.2fm", obj.width, obj.depth, obj.height)
        case .door(let d):
            return String(format: "Width: %.2fm • Height: %.2fm • %@", d.width, d.height, d.isOpen ? "Swing Open" : "Closed")
        case .window(let w):
            return String(format: "Width: %.2fm • Height: %.2fm", w.width, w.height)
        case .wall(let wall):
            return String(format: "Length: %.2fm • Height: %.2fm • Thick: %.2fm", wall.length, wall.height, wall.thickness)
        }
    }
    
    public var iconName: String {
        switch self {
        case .furniture(let obj): return obj.category.systemIcon
        case .door: return "door.left.hand.open"
        case .window: return "window.vertical.closed"
        case .wall: return "square.split.diagonal.2x2"
        }
    }
    
    public var accentColor: Color {
        switch self {
        case .furniture(let obj): return obj.category.accentColor
        case .door: return .blue
        case .window: return .cyan
        case .wall: return .primary
        }
    }
}

public struct SelectedItemInspectorView: View {
    public var element: InspectableElement
    public var onDelete: () -> Void
    public var onRotate: () -> Void
    public var onNudge: (Float, Float) -> Void // dx, dz in meters
    public var onDuplicate: (() -> Void)? = nil
    public var onToggleState: (() -> Void)? = nil
    public var onDeselect: () -> Void
    
    @State private var showNudgePad = false
    
    // Convenience initializer for FurnitureObject (backward compatibility)
    public init(
        object: FurnitureObject,
        onDelete: @escaping () -> Void,
        onRotate: @escaping () -> Void,
        onNudge: @escaping (Float, Float) -> Void,
        onDuplicate: @escaping () -> Void,
        onDeselect: @escaping () -> Void
    ) {
        self.element = .furniture(object)
        self.onDelete = onDelete
        self.onRotate = onRotate
        self.onNudge = onNudge
        self.onDuplicate = onDuplicate
        self.onToggleState = nil
        self.onDeselect = onDeselect
    }
    
    public init(
        element: InspectableElement,
        onDelete: @escaping () -> Void,
        onRotate: @escaping () -> Void,
        onNudge: @escaping (Float, Float) -> Void,
        onDuplicate: (() -> Void)? = nil,
        onToggleState: (() -> Void)? = nil,
        onDeselect: @escaping () -> Void
    ) {
        self.element = element
        self.onDelete = onDelete
        self.onRotate = onRotate
        self.onNudge = onNudge
        self.onDuplicate = onDuplicate
        self.onToggleState = onToggleState
        self.onDeselect = onDeselect
    }
    
    public var body: some View {
        VStack(spacing: 12) {
            // Header Info Bar
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(element.accentColor.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: element.iconName)
                        .font(.system(size: 18))
                        .foregroundColor(element.accentColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(element.title)
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Text(element.subtitle)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button {
                    onDeselect()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.secondary)
                }
            }
            
            Divider()
            
            // Action Buttons Row
            HStack(spacing: 10) {
                // Rotate Button
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onRotate()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 15, weight: .bold))
                        Text("Rotate 90°")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.primary)
                }
                
                // Toggle Swing (for doors)
                if case .door = element {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onToggleState?()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "door.left.hand.closed")
                                .font(.system(size: 15, weight: .bold))
                            Text("Toggle Swing")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.primary)
                    }
                }
                
                // Duplicate Button (if available)
                if let onDup = onDuplicate {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onDup()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "plus.square.on.square")
                                .font(.system(size: 15, weight: .bold))
                            Text("Duplicate")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.primary)
                    }
                }
                
                // Nudge Pad Toggle
                Button {
                    withAnimation(.spring()) {
                        showNudgePad.toggle()
                    }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.system(size: 15, weight: .bold))
                        Text(showNudgePad ? "Hide Nudge" : "Nudge")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(showNudgePad ? Color.blue.opacity(0.18) : Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(showNudgePad ? .blue : .primary)
                }
                
                // Delete Button (Destructive)
                Button(role: .destructive) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onDelete()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "trash")
                            .font(.system(size: 15, weight: .bold))
                        Text("Delete")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.red)
                }
            }
            
            // Expandable Nudge Control Pad
            if showNudgePad {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        Spacer()
                        nudgeButton(label: "Up", icon: "arrow.up", dx: 0, dz: -0.1)
                        Spacer()
                    }
                    HStack(spacing: 12) {
                        Spacer()
                        nudgeButton(label: "Left", icon: "arrow.left", dx: -0.1, dz: 0)
                        Text("10 cm")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(width: 48)
                        nudgeButton(label: "Right", icon: "arrow.right", dx: 0.1, dz: 0)
                        Spacer()
                    }
                    HStack(spacing: 12) {
                        Spacer()
                        nudgeButton(label: "Down", icon: "arrow.down", dx: 0, dz: 0.1)
                        Spacer()
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
        )
        .padding(.horizontal)
    }
    
    private func nudgeButton(label: String, icon: String, dx: Float, dz: Float) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onNudge(dx, dz)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 38, height: 32)
                .background(Color(UIColor.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                .foregroundColor(.primary)
                .shadow(color: Color.black.opacity(0.08), radius: 2)
        }
    }
}
