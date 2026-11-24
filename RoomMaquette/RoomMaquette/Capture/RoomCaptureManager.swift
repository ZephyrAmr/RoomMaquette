import Foundation
import Combine
import RoomPlan

@available(iOS 16.0, *)
public class RoomCaptureManager: ObservableObject {
    @Published public var isScanning: Bool = false
    @Published public var isDone: Bool = false
    @Published public var wallCount: Int = 0
    @Published public var doorCount: Int = 0
    @Published public var windowCount: Int = 0
    @Published public var objectCount: Int = 0
    @Published public var scanDurationSeconds: Int = 0
    @Published public var errorMessage: String? = nil
    @Published public var completedRoom: MaquetteRoom? = nil
    @Published public var isProcessing: Bool = false
    
    public var roomCaptureView: RoomCaptureView?
    public var latestCapturedRoom: CapturedRoom? = nil
    public var completedRoomRaw: CapturedRoom? = nil
    
    private var pendingCompletion: ((MaquetteRoom?) -> Void)?
    private var timer: Timer?
    private var watchdogTimer: Timer?
    
    public init() {
        if RoomCaptureSession.isSupported {
            self.roomCaptureView = RoomCaptureView()
        }
    }
    
    public func startCapture() {
        guard RoomCaptureSession.isSupported else {
            errorMessage = "LiDAR is not supported on this device. Use an iPhone 12 Pro or newer, or explore sample scans."
            return
        }
        
        isScanning = true
        isDone = false
        isProcessing = false
        wallCount = 0
        doorCount = 0
        windowCount = 0
        objectCount = 0
        scanDurationSeconds = 0
        errorMessage = nil
        completedRoom = nil
        latestCapturedRoom = nil
        completedRoomRaw = nil
        pendingCompletion = nil
        
        let config = RoomCaptureSession.Configuration()
        roomCaptureView?.captureSession.run(configuration: config)
        
        // Start duration timer
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.scanDurationSeconds += 1
            }
        }
    }
    
    public func stopCapture(completion: @escaping (MaquetteRoom?) -> Void) {
        timer?.invalidate()
        timer = nil
        isScanning = false
        isProcessing = true
        self.pendingCompletion = completion
        
        guard let view = roomCaptureView else {
            finishCapture(with: nil)
            return
        }
        
        // Stop the capture session to trigger post-processing
        view.captureSession.stop()
        
        // Safety watchdog: In case delegate callback doesn't arrive within 3.5 seconds,
        // construct room directly from latestCapturedRoom
        watchdogTimer?.invalidate()
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.pendingCompletion != nil else { return }
                if let captured = self.completedRoomRaw ?? self.latestCapturedRoom {
                    let maquette = self.buildMaquetteRoom(from: captured)
                    self.finishCapture(with: maquette)
                } else {
                    self.finishCapture(with: nil)
                }
            }
        }
    }
    
    public func handleFinalizedRoom(_ room: CapturedRoom?) {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        
        guard let room = room else {
            if let latest = latestCapturedRoom {
                let maquette = buildMaquetteRoom(from: latest)
                finishCapture(with: maquette)
            } else {
                finishCapture(with: nil)
            }
            return
        }
        
        self.completedRoomRaw = room
        let maquette = buildMaquetteRoom(from: room)
        finishCapture(with: maquette)
    }
    
    private func finishCapture(with room: MaquetteRoom?) {
        isProcessing = false
        isDone = true
        self.completedRoom = room
        
        if let completion = self.pendingCompletion {
            self.pendingCompletion = nil
            completion(room)
        }
    }
    
    public func buildMaquetteRoom(from captured: CapturedRoom) -> MaquetteRoom {
        let df = DateFormatter()
        df.dateFormat = "MMM d, HH-mm"
        let scanName = "Room Scan \(df.string(from: Date()))"
        
        // Export native certified USDZ mesh from RoomPlan if possible
        var usdzData: Data? = nil
        let tempExportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RoomScan_\(UUID().uuidString).usdz")
        
        if (try? captured.export(to: tempExportURL, exportOptions: .mesh)) != nil {
            usdzData = try? Data(contentsOf: tempExportURL)
            try? FileManager.default.removeItem(at: tempExportURL)
        }
        
        return MaquetteRoom(
            from: captured,
            name: scanName,
            usdzData: usdzData
        )
    }
    
    public func cancelCapture() {
        timer?.invalidate()
        timer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        roomCaptureView?.captureSession.stop()
        isScanning = false
        isProcessing = false
        isDone = false
        latestCapturedRoom = nil
        completedRoomRaw = nil
        pendingCompletion = nil
    }
    
    public func updateLiveStats(walls: Int, doors: Int, windows: Int, objects: Int) {
        self.wallCount = walls
        self.doorCount = doors
        self.windowCount = windows
        self.objectCount = objects
    }
}
