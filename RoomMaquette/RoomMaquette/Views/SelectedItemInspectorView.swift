import SwiftUI
import simd

public enum InspectableElement {
    case furniture(FurnitureObject)
    case door(DoorSurface)
    case window(WindowSurface)
    case opening(OpeningSurface)
    case wall(WallSurface)
    
    public var id: UUID {
        switch self {
        case .furniture(let obj): return obj.id
        case .door(let d): return d.id
        case .window(let w): return w.id
        case .opening(let op): return op.id
        case .wall(let wall): return wall.id
        }
    }
    
    public var title: String {
        switch self {
        case .furniture(let obj): return obj.displayName
        case .door: return "Architectural Door"
        case .window: return "Architectural Window"
        case .opening: return "Archway / Opening"
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
        case .opening(let op):
            return String(format: "Width: %.2fm • Height: %.2fm", op.width, op.height)
        case .wall(let wall):
            return String(format: "Length: %.2fm • Height: %.2fm • Thick: %.2fm", wall.length, wall.height, wall.thickness)
        }
    }
    
    public var rotationDegrees: Int {
        let rad: Float
        switch self {
        case .furniture(let obj): rad = obj.rotationY
        case .door(let d): rad = d.transform.rotationY
        case .window(let w): rad = w.transform.rotationY
        case .opening(let op): rad = op.transform.rotationY
        case .wall(let wall): rad = wall.transform.rotationY
        }
        let deg = Int((rad * 180.0 / .pi).rounded()) % 360
        return deg < 0 ? deg + 360 : deg
    }
    
    public var iconName: String {
        switch self {
        case .furniture(let obj): return obj.category.systemIcon
        case .door: return "door.left.hand.open"
        case .window: return "window.vertical.closed"
        case .opening: return "rectangle.dashed"
        case .wall: return "square.split.diagonal.2x2"
        }
    }
    
    public var accentColor: Color {
        switch self {
        case .furniture(let obj): return obj.category.accentColor
        case .door: return .blue
        case .window: return .cyan
        case .opening: return .teal
        case .wall: return .primary
        }
    }
}

public struct SelectedItemInspectorView: View {
    public var element: InspectableElement
    public var onDelete: () -> Void
    public var onRotate: () -> Void
    public var onRotateBy: ((Float) -> Void)? = nil // radians
    public var onNudge: (Float, Float) -> Void     // dx, dz in meters
    public var onResize: ((Float, Float, Float) -> Void)? = nil // dWidth(len), dHeight, dDepth(thick)
    public var onDuplicate: (() -> Void)? = nil
    public var onToggleState: (() -> Void)? = nil
    public var onDeselect: () -> Void
    
    private enum ControlPanelTab: String, CaseIterable {
        case move = "Move"
        case rotate = "Rotate"
        case size = "Size"
    }
    
    @State private var expandedPanel: ControlPanelTab? = nil
    @State private var nudgeStepMeters: Float = 0.05
    
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
        onRotateBy: ((Float) -> Void)? = nil,
        onNudge: @escaping (Float, Float) -> Void,
        onResize: ((Float, Float, Float) -> Void)? = nil,
        onDuplicate: (() -> Void)? = nil,
        onToggleState: (() -> Void)? = nil,
        onDeselect: @escaping () -> Void
    ) {
        self.element = element
        self.onDelete = onDelete
        self.onRotate = onRotate
        self.onRotateBy = onRotateBy
        self.onNudge = onNudge
        self.onResize = onResize
        self.onDuplicate = onDuplicate
        self.onToggleState = onToggleState
        self.onDeselect = onDeselect
    }
    
    public var body: some View {
        VStack(spacing: 10) {
            // Header Info Bar
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(element.accentColor.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: element.iconName)
                        .font(.system(size: 17))
                        .foregroundColor(element.accentColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(element.title)
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Text("\(element.subtitle) • \(element.rotationDegrees)°")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
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
            HStack(spacing: 8) {
                // Fine Move / Nudge Panel Toggle
                panelButton(tab: .move, title: "Move", icon: "arrow.up.and.down.and.arrow.left.and.right")
                
                // Fine Rotate Panel Toggle
                panelButton(tab: .rotate, title: "Rotate", icon: "rotate.right")
                
                // Fine Resize Panel Toggle
                if onResize != nil {
                    panelButton(tab: .size, title: "Size", icon: "ruler")
                }
                
                // Toggle Swing (for doors)
                if case .door = element {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onToggleState?()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "door.left.hand.closed")
                                .font(.system(size: 14, weight: .bold))
                            Text("Swing")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.primary)
                    }
                }
                
                // Duplicate Button
                if let onDup = onDuplicate {
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        onDup()
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "plus.square.on.square")
                                .font(.system(size: 14, weight: .bold))
                            Text("Copy")
                                .font(.system(size: 9.5, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.primary)
                    }
                }
                
                // Delete Button
                Button(role: .destructive) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onDelete()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .bold))
                        Text("Delete")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundColor(.red)
                }
            }
            
            // Expandable Granular Control Sub-Panels
            if let panel = expandedPanel {
                Divider()
                switch panel {
                case .move:
                    granularMovePad
                case .rotate:
                    granularRotatePad
                case .size:
                    granularResizePad
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .shadow(color: Color.black.opacity(0.15), radius: 10, y: 4)
        )
        .padding(.horizontal)
    }
    
    private func panelButton(tab: ControlPanelTab, title: String, icon: String) -> some View {
        let isActive = (expandedPanel == tab)
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                expandedPanel = isActive ? nil : tab
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isActive ? Color.blue.opacity(0.18) : Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 10))
            .foregroundColor(isActive ? .blue : .primary)
        }
    }
    
    // MARK: - Granular Move / Nudge Pad
    
    private var granularMovePad: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("Step:")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                Picker("Step", selection: $nudgeStepMeters) {
                    Text("1 cm").tag(Float(0.01))
                    Text("5 cm").tag(Float(0.05))
                    Text("20 cm").tag(Float(0.20))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
                Spacer()
                Text("Tip: drag on 2D")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            
            HStack(spacing: 12) {
                Spacer()
                nudgeButton(icon: "arrow.up", dx: 0, dz: -nudgeStepMeters)
                Spacer()
            }
            HStack(spacing: 12) {
                Spacer()
                nudgeButton(icon: "arrow.left", dx: -nudgeStepMeters, dz: 0)
                Text("\(Int(nudgeStepMeters * 100)) cm")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 50)
                nudgeButton(icon: "arrow.right", dx: nudgeStepMeters, dz: 0)
                Spacer()
            }
            HStack(spacing: 12) {
                Spacer()
                nudgeButton(icon: "arrow.down", dx: 0, dz: nudgeStepMeters)
                Spacer()
            }
        }
    }
    
    // MARK: - Granular Rotation Pad
    
    private var granularRotatePad: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                rotateStepButton(label: "-45°", degrees: -45)
                rotateStepButton(label: "-5°", degrees: -5)
                rotateStepButton(label: "-1°", degrees: -1)
                rotateStepButton(label: "+1°", degrees: 1)
                rotateStepButton(label: "+5°", degrees: 5)
                rotateStepButton(label: "+45°", degrees: 45)
                rotateStepButton(label: "+90°", degrees: 90)
            }
        }
    }
    
    private func rotateStepButton(label: String, degrees: Float) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if let rotBy = onRotateBy {
                rotBy(degrees * .pi / 180.0)
            } else {
                onRotate()
            }
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .foregroundColor(.primary)
        }
    }
    
    // MARK: - Granular Dimension Resize Pad
    
    private var granularResizePad: some View {
        VStack(spacing: 7) {
            switch element {
            case .wall:
                dimensionStepRow(title: "Length", deltaSmall: 0.05, deltaLarge: 0.25) { d in
                    onResize?(d, 0, 0)
                }
                dimensionStepRow(title: "Thick", deltaSmall: 0.02, deltaLarge: 0.05) { d in
                    onResize?(0, 0, d)
                }
                dimensionStepRow(title: "Height", deltaSmall: 0.05, deltaLarge: 0.20) { d in
                    onResize?(0, d, 0)
                }
            case .door, .window, .opening:
                dimensionStepRow(title: "Width", deltaSmall: 0.02, deltaLarge: 0.10) { d in
                    onResize?(d, 0, 0)
                }
                dimensionStepRow(title: "Height", deltaSmall: 0.05, deltaLarge: 0.20) { d in
                    onResize?(0, d, 0)
                }
            case .furniture:
                dimensionStepRow(title: "Width", deltaSmall: 0.05, deltaLarge: 0.20) { d in
                    onResize?(d, 0, 0)
                }
                dimensionStepRow(title: "Depth", deltaSmall: 0.05, deltaLarge: 0.20) { d in
                    onResize?(0, 0, d)
                }
            }
        }
    }
    
    private func dimensionStepRow(title: String, deltaSmall: Float, deltaLarge: Float, apply: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 48, alignment: .leading)
            resizeBtn("-\(Int((deltaLarge * 100).rounded()))cm") { apply(-deltaLarge) }
            resizeBtn("-\(Int((deltaSmall * 100).rounded()))cm") { apply(-deltaSmall) }
            resizeBtn("+\(Int((deltaSmall * 100).rounded()))cm") { apply(deltaSmall) }
            resizeBtn("+\(Int((deltaLarge * 100).rounded()))cm") { apply(deltaLarge) }
        }
    }
    
    private func resizeBtn(_ title: String, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 7))
                .foregroundColor(.primary)
        }
    }
    
    private func nudgeButton(icon: String, dx: Float, dz: Float) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onNudge(dx, dz)
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 44, height: 34)
                .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .foregroundColor(.primary)
        }
    }
}
