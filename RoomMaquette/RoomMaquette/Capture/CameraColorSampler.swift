import Foundation
import ARKit
import CoreVideo
import simd

public class CameraColorSampler {
    
    /// Samples dominant RGB + Lab color from `frame.capturedImage` at the projection of a 3D AR world point.
    public static func sampleColor(in frame: ARFrame, atWorldPoint worldPoint: SIMD3<Float>, patchRadiusPx: Int = 8) -> SurfaceColor? {
        let invCam = simd_inverse(frame.camera.transform)
        let local = simd_mul(invCam, SIMD4<Float>(worldPoint, 1.0))
        let depth = -local.z
        guard depth >= 0.35 && depth <= 7.5 else { return nil }
        
        let K = frame.camera.intrinsics
        let fx = K.columns.0.x
        let fy = K.columns.1.y
        let cx = K.columns.2.x
        let cy = K.columns.2.y
        guard fx > 1 && fy > 1 else { return nil }
        
        let px = Int(cx + fx * (local.x / depth))
        let py = Int(cy - fy * (local.y / depth))
        
        return samplePixelPatch(pixelBuffer: frame.capturedImage, centerX: px, centerY: py, radius: patchRadiusPx)
    }
    
    /// Samples dominant color near the center of the camera frame.
    public static func sampleCenterColor(in frame: ARFrame, radiusPx: Int = 12) -> SurfaceColor? {
        let buf = frame.capturedImage
        let w = CVPixelBufferGetWidth(buf)
        let h = CVPixelBufferGetHeight(buf)
        return samplePixelPatch(pixelBuffer: buf, centerX: w / 2, centerY: h / 2, radius: radiusPx)
    }
    
    private static func samplePixelPatch(pixelBuffer: CVPixelBuffer, centerX: Int, centerY: Int, radius: Int) -> SurfaceColor? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return nil }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let w1 = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let h1 = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        
        // Ignore outer 10% border to avoid vignette/off-target pixels
        let marginX = max(w / 10, radius + 2)
        let marginY = max(h / 10, radius + 2)
        guard centerX >= marginX && centerX < w - marginX &&
              centerY >= marginY && centerY < h - marginY else {
            return nil
        }
        
        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self) else {
            return nil
        }
        
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let isVideoRange = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        
        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0
        var count: Int = 0
        
        let step = max(radius / 2, 2)
        for dy in stride(from: -radius, through: radius, by: step) {
            let py = centerY + dy
            let uvY = min(max(py / 2, 0), h1 - 1)
            for dx in stride(from: -radius, through: radius, by: step) {
                let px = centerX + dx
                let uvX = min(max(px / 2, 0), w1 - 1)
                
                let yRaw = Float(yBase[py * yStride + px])
                let uvIdx = uvY * uvStride + uvX * 2
                let cbRaw = Float(uvBase[uvIdx])
                let crRaw = Float(uvBase[uvIdx + 1])
                
                let yVal = isVideoRange ? max(0, (yRaw - 16.0) / 219.0) : (yRaw / 255.0)
                let cb = (cbRaw - 128.0) / (isVideoRange ? 224.0 : 255.0)
                let cr = (crRaw - 128.0) / (isVideoRange ? 224.0 : 255.0)
                
                let r = max(0, min(1, yVal + 1.402 * cr))
                let g = max(0, min(1, yVal - 0.344136 * cb - 0.714136 * cr))
                let b = max(0, min(1, yVal + 1.772 * cb))
                
                sumR += r
                sumG += g
                sumB += b
                count += 1
            }
        }
        
        guard count > 0 else { return nil }
        let n = Float(count)
        return SurfaceColor(r: sumR / n, g: sumG / n, b: sumB / n, sampleCount: 1)
    }
}
