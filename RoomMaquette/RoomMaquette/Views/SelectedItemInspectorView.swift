import SwiftUI
import simd

public struct SelectedItemInspectorView: View {
    public var object: FurnitureObject
    public var onDelete: () -> Void
    public var onRotate: () -> Void
    public var onNudge: (Float, Float) -> Void // dx, dz in meters
    public var onDuplicate: () -> Void
    public var onDeselect: () -> Void
    
    public init(
        object: FurnitureObject,
        onDelete: @escaping () -> Void,
        onRotate: @escaping () -> Void,
        onNudge: @escaping (Float, Float) -> Void,
        onDuplicate: @escaping () -> Void,
        onDeselect: @escaping () -> Void
    ) {
        self.object = object
        self.onDelete = onDelete
        self.onRotate = onRotate
        self.onNudge = onNudge
        self.onDuplicate = onDuplicate
        self.onDeselect = onDeselect
    }
    
    public var body: some View {
        VStack(spacing: 12) {
            // Header Info Bar
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(object.category.accentColor.opacity(0.18))
                        .frame(width: 38, height: 38)
                    Image(systemName: object.category.systemIcon)
                        .font(.system(size: 18))
                        .foregroundColor(object.category.accentColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(object.displayName)
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Text(String(format: "%.2fm × %.2fm • H: %.2fm", object.width, object.depth, object.height))
                        .font(.caption2)
                        .fontDesign(.monospaced)
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
            
            // Action Buttons
            HStack(spacing: 14) {
                // Rotate Button
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onRotate()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 16, weight: .bold))
                        Text("Rotate 45°")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.primary)
                }
                
                // Duplicate Button
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onDuplicate()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus.square.on.square")
                            .font(.system(size: 16, weight: .bold))
                        Text("Duplicate")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.primary)
                }
                
                // Delete Button (Destructive)
                Button(role: .destructive) {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    onDelete()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 16, weight: .bold))
                        Text("Delete")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.red)
                }
            }
            
            // Position Nudge Pad
            HStack(spacing: 8) {
                Text("NUDGE:")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Button {
                    onNudge(-0.15, 0)
                } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 28)
                        .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                }
                
                Button {
                    onNudge(0.15, 0)
                } label: {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 28)
                        .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                }
                
                Button {
                    onNudge(0, -0.15)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 28)
                        .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                }
                
                Button {
                    onNudge(0, 0.15)
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 32, height: 28)
                        .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                }
                
                Spacer()
                
                Text(String(format: "Pos: (%.2f, %.2f)", object.position.x, object.position.z))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
        .padding(.horizontal)
    }
}
