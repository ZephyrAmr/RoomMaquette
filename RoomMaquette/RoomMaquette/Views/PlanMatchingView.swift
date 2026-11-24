import SwiftUI
import simd

public struct PlanMatchingView: View {
    @Environment(\.dismiss) private var dismiss
    public var room: MaquetteRoom
    @Binding public var plan: ImportedPlan
    public var onSave: (PlanAlignmentTransform) -> Void
    public var onApplyPlanRescale: ((ImportedPlan) -> Void)? = nil
    
    @State private var currentTransform: PlanAlignmentTransform
    @State private var isAutoMatching: Bool = false
    @State private var overlayOpacity: Double = 0.65
    @State private var dragStartOffset: SIMD2<Float>? = nil
    
    // 2-Point Scale Calibration State
    @State private var isCalibratingScale: Bool = false
    @State private var calPointA: SIMD2<Float>? = nil
    @State private var calPointB: SIMD2<Float>? = nil
    @State private var knownLengthInput: String = "4.0"
    
    public init(
        room: MaquetteRoom,
        plan: Binding<ImportedPlan>,
        onSave: @escaping (PlanAlignmentTransform) -> Void,
        onApplyPlanRescale: ((ImportedPlan) -> Void)? = nil
    ) {
        self.room = room
        self._plan = plan
        self.onSave = onSave
        self.onApplyPlanRescale = onApplyPlanRescale
        self._currentTransform = State(initialValue: plan.wrappedValue.alignment)
    }
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isCalibratingScale {
                    HStack(spacing: 8) {
                        Image(systemName: "ruler.fill")
                            .foregroundColor(.orange)
                        Text(calibrationPromptText)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        Spacer()
                        if calPointA != nil {
                            Button("Clear") {
                                calPointA = nil
                                calPointB = nil
                            }
                            .font(.caption.bold())
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.14))
                }
                
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
            .navigationTitle(isCalibratingScale ? "Calibrate Plan Scale" : "Align Scan to Plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(currentTransform)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
    
    private var calibrationPromptText: String {
        if calPointA == nil {
            return "Step 1: Tap start of a wall with known length"
        } else if calPointB == nil {
            return "Step 2: Tap end of that wall"
        } else {
            return "Step 3: Enter actual length in meters & Apply"
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
                        .frame(
                            width: CGFloat(plan.originalWidthMeters) * scaleFactor,
                            height: CGFloat(plan.originalDepthMeters) * scaleFactor
                        )
                        .opacity(overlayOpacity)
                        .shadow(radius: 4)
                } else {
                    Color(red: 0.08, green: 0.16, blue: 0.32)
                }
                
                // Vector lines extracted from blueprint
                Canvas { ctx, _ in
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
                        with: .color(plan.renderedImageData != nil ? .blue.opacity(0.65) : .white.opacity(0.8)),
                        lineWidth: 1.5
                    )
                    
                    // Draw 2-Point Calibration Ruler if active
                    if isCalibratingScale, let a = calPointA {
                        let ca = CGPoint(x: midX + CGFloat(a.x) * scaleFactor, y: midY + CGFloat(a.y) * scaleFactor)
                        let dotA = Path(ellipseIn: CGRect(x: ca.x - 7, y: ca.y - 7, width: 14, height: 14))
                        ctx.fill(dotA, with: .color(.orange))
                        ctx.stroke(dotA, with: .color(.white), lineWidth: 2)
                        
                        if let b = calPointB {
                            let cb = CGPoint(x: midX + CGFloat(b.x) * scaleFactor, y: midY + CGFloat(b.y) * scaleFactor)
                            var linePath = Path()
                            linePath.move(to: ca)
                            linePath.addLine(to: cb)
                            ctx.stroke(linePath, with: .color(.orange), lineWidth: 3)
                            
                            let dotB = Path(ellipseIn: CGRect(x: cb.x - 7, y: cb.y - 7, width: 14, height: 14))
                            ctx.fill(dotB, with: .color(.orange))
                            ctx.stroke(dotB, with: .color(.white), lineWidth: 2)
                            
                            let curLen = simd_distance(a, b)
                            let midPt = CGPoint(x: (ca.x + cb.x) * 0.5, y: (ca.y + cb.y) * 0.5 - 14)
                            ctx.draw(
                                Text(String(format: "%.2f m", curLen))
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(.orange),
                                at: midPt
                            )
                        }
                    }
                }
                .allowsHitTesting(false)
                
                // 2. Render Transformed LiDAR Scan Walls (Foreground Overlay)
                if !isCalibratingScale && !room.notes.hasPrefix("Created from imported plan:") {
                    Canvas { context, _ in
                        let rot = Double(currentTransform.rotationAngle)
                        let tx = CGFloat(currentTransform.offsetX) * scaleFactor
                        let tz = CGFloat(currentTransform.offsetZ) * scaleFactor
                        let sc = CGFloat(currentTransform.scale) * scaleFactor
                        
                        context.drawLayer { lctx in
                            lctx.translateBy(x: midX + tx, y: midY + tz)
                            lctx.rotate(by: Angle(radians: rot))
                            
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
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { loc in
                guard isCalibratingScale else { return }
                let px = Float((loc.x - midX) / scaleFactor)
                let pz = Float((loc.y - midY) / scaleFactor)
                let pt = SIMD2<Float>(px, pz)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if calPointA == nil || (calPointA != nil && calPointB != nil) {
                    calPointA = pt
                    calPointB = nil
                } else {
                    calPointB = pt
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        guard !isCalibratingScale else { return }
                        if dragStartOffset == nil {
                            dragStartOffset = SIMD2<Float>(currentTransform.offsetX, currentTransform.offsetZ)
                        }
                        if let start = dragStartOffset {
                            currentTransform.offsetX = start.x + Float(value.translation.width / scaleFactor)
                            currentTransform.offsetZ = start.y + Float(value.translation.height / scaleFactor)
                        }
                    }
                    .onEnded { _ in
                        dragStartOffset = nil
                    }
            )
        }
    }
    
    // MARK: - Control Panel
    
    private var controlPanel: some View {
        VStack(spacing: 12) {
            // Mode Switch: Align Scan vs 2-Point Scale Calibration
            Picker("Calibration Mode", selection: $isCalibratingScale) {
                Text("Align Scan").tag(false)
                Text("2-Point Scale").tag(true)
            }
            .pickerStyle(.segmented)
            
            if isCalibratingScale {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Text("Plan Span: \(String(format: "%.1fm × %.1fm", plan.originalWidthMeters, plan.originalDepthMeters))")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    
                    HStack(spacing: 10) {
                        Text("Actual Length (m):")
                            .font(.caption.bold())
                        TextField("e.g. 4.2", text: $knownLengthInput)
                            .keyboardType(.decimalPad)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        
                        Button {
                            applyTwoPointScale()
                        } label: {
                            Text("Apply Scale")
                                .font(.caption.bold())
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background((calPointA != nil && calPointB != nil) ? Color.orange : Color.gray, in: RoundedRectangle(cornerRadius: 8))
                                .foregroundColor(.white)
                        }
                        .disabled(calPointA == nil || calPointB == nil)
                    }
                }
            } else {
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
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Button {
                            withAnimation {
                                currentTransform.rotationAngle -= .pi / 2.0
                            }
                        } label: {
                            Text("-90°")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(width: 38, height: 34)
                                .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Button {
                            currentTransform.rotationAngle -= (5.0 * .pi / 180.0)
                        } label: {
                            Text("-5°")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(width: 34, height: 34)
                                .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Button {
                            currentTransform.rotationAngle += (5.0 * .pi / 180.0)
                        } label: {
                            Text("+5°")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(width: 34, height: 34)
                                .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        }
                        
                        Button {
                            withAnimation {
                                currentTransform.rotationAngle += .pi / 2.0
                            }
                        } label: {
                            Text("+90°")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .frame(width: 38, height: 34)
                                .background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    
                    Divider().frame(height: 28)
                    
                    HStack(spacing: 6) {
                        Button { currentTransform.offsetX -= 0.20 } label: {
                            Image(systemName: "arrow.left").frame(width: 30, height: 34).background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        }
                        Button { currentTransform.offsetX += 0.20 } label: {
                            Image(systemName: "arrow.right").frame(width: 30, height: 34).background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        }
                        Button { currentTransform.offsetZ -= 0.20 } label: {
                            Image(systemName: "arrow.up").frame(width: 30, height: 34).background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        }
                        Button { currentTransform.offsetZ += 0.20 } label: {
                            Image(systemName: "arrow.down").frame(width: 30, height: 34).background(Color(UIColor.secondarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                
                // Continuous Fine Angle Slider + Opacity
                HStack(spacing: 12) {
                    Text("Angle \(Int((currentTransform.rotationAngle * 180.0 / .pi).rounded()))°")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .frame(width: 68, alignment: .leading)
                    Slider(value: Binding(
                        get: { Double(currentTransform.rotationAngle) },
                        set: { currentTransform.rotationAngle = Float($0) }
                    ), in: -Double.pi...Double.pi)
                    
                    Text("Opacity")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Slider(value: $overlayOpacity, in: 0.1...1.0)
                        .frame(width: 75)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemGroupedBackground))
    }
    
    private func applyTwoPointScale() {
        guard let a = calPointA, let b = calPointB else { return }
        let measured = simd_distance(a, b)
        let cleanStr = knownLengthInput.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard measured > 0.05, let targetMeters = Float(cleanStr), targetMeters > 0.2 else { return }
        
        let factor = targetMeters / measured
        let updatedPlan = PlanImporter.rescaledPlan(plan, by: factor)
        plan = updatedPlan
        onApplyPlanRescale?(updatedPlan)
        calPointA = nil
        calPointB = nil
        UINotificationFeedbackGenerator().notificationOccurred(.success)
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
