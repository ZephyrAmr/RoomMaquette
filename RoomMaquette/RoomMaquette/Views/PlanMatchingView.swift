import SwiftUI
import simd

public struct PlanMatchingView: View {
    @Environment(\.dismiss) private var dismiss
    public var room: MaquetteRoom
    @Binding public var plan: ImportedPlan
    public var onSave: (PlanAlignmentTransform) -> Void
    
    @State private var currentTransform: PlanAlignmentTransform
    @State private var isAutoMatching: Bool = false
    @State private var overlayOpacity: Double = 0.65
    
    public init(room: MaquetteRoom, plan: Binding<ImportedPlan>, onSave: @escaping (PlanAlignmentTransform) -> Void) {
        self.room = room
        self._plan = plan
        self.onSave = onSave
        self._currentTransform = State(initialValue: plan.wrappedValue.alignment)
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Main Alignment Canvas Area
                ZStack {
                    Color(UIColor.systemGroupedBackground)
                        .ignoresSafeArea()
                    
                    alignmentCanvas
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(12)
                }
                
                // Bottom Calibration Controls Card
                controlPanel
            }
            .navigationTitle("Align Scan to Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Alignment") {
                        onSave(currentTransform)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
    
    // MARK: - Canvas View
    
    private var alignmentCanvas: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let midX = size.width / 2.0
            let midY = size.height / 2.0
            let scaleFactor: CGFloat = min(size.width / CGFloat(max(plan.originalWidthMeters, 5.0)),
                                           size.height / CGFloat(max(plan.originalDepthMeters, 5.0))) * 0.75
            
            ZStack {
                // 1. Render Imported Blueprint (Background Layer)
                if let data = plan.renderedImageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: size.width - 40, maxHeight: size.height - 40)
                        .opacity(overlayOpacity)
                        .shadow(radius: 4)
                } else {
                    // Blueprint paper with vector lines
                    Color(red: 0.08, green: 0.16, blue: 0.32)
                        .overlay {
                            Canvas { ctx, csize in
                                ctx.stroke(
                                    Path { p in
                                        for line in plan.vectorLines {
                                            let p1 = CGPoint(x: midX + CGFloat(line.startX) * scaleFactor,
                                                             y: midY + CGFloat(line.startZ) * scaleFactor)
                                            let p2 = CGPoint(x: midX + CGFloat(line.endX) * scaleFactor,
                                                             y: midY + CGFloat(line.endZ) * scaleFactor)
                                            p.move(to: p1)
                                            p.addLine(to: p2)
                                        }
                                    },
                                    with: .color(.white.opacity(0.8)),
                                    lineWidth: 1.5
                                )
                            }
                        }
                }
                
                // 2. Render Transformed LiDAR Scan Walls (Foreground Overlay)
                Canvas { context, _ in
                    let rot = Double(currentTransform.rotationAngle)
                    let tx = CGFloat(currentTransform.offsetX) * scaleFactor
                    let tz = CGFloat(currentTransform.offsetZ) * scaleFactor
                    let sc = CGFloat(currentTransform.scale) * scaleFactor
                    
                    context.drawLayer { lctx in
                        lctx.translateBy(x: midX + tx, y: midY + tz)
                        lctx.rotate(by: Angle(radians: rot))
                        
                        // Draw LiDAR Walls in vibrant cyan/electric blue
                        for wall in room.walls {
                            let s = wall.startPoint2D
                            let e = wall.endPoint2D
                            let p1 = CGPoint(x: CGFloat(s.x) * sc, y: CGFloat(s.y) * sc)
                            let p2 = CGPoint(x: CGFloat(e.x) * sc, y: CGFloat(e.y) * sc)
                            
                            var path = Path()
                            path.move(to: p1)
                            path.addLine(to: p2)
                            
                            lctx.stroke(
                                path,
                                with: .color(Color.cyan),
                                style: StrokeStyle(lineWidth: 4, lineCap: .round)
                            )
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Control Panel
    
    private var controlPanel: some View {
        VStack(spacing: 12) {
            // Auto-Match Button
            Button {
                runAutoMatch()
            } label: {
                HStack(spacing: 8) {
                    if isAutoMatching {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text("Auto-Match Scan to Plan")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
                .foregroundColor(.white)
            }
            .disabled(isAutoMatching)
            
            // Manual Rotation & Nudge Controls
            HStack(spacing: 16) {
                // Rotation
                HStack(spacing: 8) {
                    Button {
                        withAnimation {
                            currentTransform.rotationAngle -= .pi / 2.0
                        }
                    } label: {
                        Image(systemName: "rotate.left")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 40, height: 36)
                            .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                    
                    Button {
                        withAnimation {
                            currentTransform.rotationAngle += .pi / 2.0
                        }
                    } label: {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 16, weight: .bold))
                            .frame(width: 40, height: 36)
                            .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                
                Divider().frame(height: 28)
                
                // Nudge Controls
                HStack(spacing: 6) {
                    Button {
                        currentTransform.offsetX -= 0.25
                    } label: {
                        Image(systemName: "arrow.left")
                            .frame(width: 32, height: 32)
                            .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Button {
                        currentTransform.offsetX += 0.25
                    } label: {
                        Image(systemName: "arrow.right")
                            .frame(width: 32, height: 32)
                            .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Button {
                        currentTransform.offsetZ -= 0.25
                    } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 32, height: 32)
                            .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    }
                    Button {
                        currentTransform.offsetZ += 0.25
                    } label: {
                        Image(systemName: "arrow.down")
                            .frame(width: 32, height: 32)
                            .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            
            // Scale & Opacity Sliders
            HStack(spacing: 14) {
                Text("Scale")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(value: Binding(
                    get: { Double(currentTransform.scale) },
                    set: { currentTransform.scale = Float($0) }
                ), in: 0.5...2.0)
                
                Text("Opacity")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Slider(value: $overlayOpacity, in: 0.1...1.0)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
    }
    
    private func runAutoMatch() {
        isAutoMatching = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PlanAutoMatcher.match(scan: room, plan: plan)
            DispatchQueue.main.async {
                self.isAutoMatching = false
                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                    self.currentTransform = result
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }
}
