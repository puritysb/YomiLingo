//
//  ARFrameProcessor.swift
//  ViewLingo-Cam
//
//  Process ARFrames for OCR in ARKit mode
//

import Foundation
@preconcurrency import ARKit
import Vision
@preconcurrency import CoreImage

@available(iOS 18.0, *)
class ARFrameProcessor: NSObject, ARSessionDelegate {
    // MARK: - Properties
    
    let ocrService: OCRService
    var onTextDetected: (([OCRService.RecognizedText]) -> Void)?
    var isLiveModeEnabled: Bool = false  // Control flag for Live mode
    
    private var lastProcessedTime: TimeInterval = 0
    private let processingInterval: TimeInterval = 0.2  // Process every 0.2 seconds for better responsiveness
    private var frameCount = 0
    private var isProcessing = false
    private let processingQueue = DispatchQueue(label: "ar.frame.processor", qos: .userInitiated)
    // Frame skipping removed - process based on time interval only
    
    // MARK: - Initialization
    
    init(ocrService: OCRService) {
        self.ocrService = ocrService
        super.init()
    }
    
    // MARK: - ARSessionDelegate
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Use autoreleasepool to ensure ARFrame is released immediately
        autoreleasepool {
            // Skip if Live mode is not enabled
            guard isLiveModeEnabled else { 
                // Only log when frames would be processed
                if frameCount % 90 == 0 {  // Log less frequently when not processing
                    Logger.shared.log(.debug, "ARFrameProcessor: Skipping frames - Live mode disabled")
                }
                frameCount += 1
                return 
            }
            
            // Debug: Log frame reception (only when actually processing)
            if frameCount % 30 == 0 {  // Log every 30 frames (~1 second)
                Logger.shared.log(.debug, "ARFrameProcessor: Processing frames in Live mode")
            }
            
            let timestamp = frame.timestamp
            
            // Skip if too soon or already processing
            guard timestamp - lastProcessedTime >= processingInterval,
                  !isProcessing else { 
                if frameCount % 30 == 0 {
                    Logger.shared.log(.debug, "ARFrameProcessor: Skipping frame - too soon or processing")
                }
                return 
            }
            
            // Update timing
            lastProcessedTime = timestamp
            frameCount += 1
            
            // CRITICAL: Copy pixel buffer immediately and release ARFrame
            let pixelBuffer = frame.capturedImage
            
            // Create a copy of the pixel buffer
            guard let copiedBuffer = copyPixelBuffer(pixelBuffer) else {
                return
            }
            
            // Process asynchronously without holding frame reference
            Task.detached { [weak self] in
                self?.processWithOCRService(copiedBuffer)
            }
            
            // ARFrame is released here when autoreleasepool drains
        }
    }
    
    // MARK: - Private Methods
    
    private func processWithOCRService(_ pixelBuffer: CVPixelBuffer) {
        // Ensure we don't process if already processing
        guard !isProcessing else { return }
        isProcessing = true
        
        // Wrap buffer in UnsafeSendable before capturing in async closure
        let sendableBuffer = UnsafeSendable(pixelBuffer)
        
        // Process on background queue with autoreleasepool
        processingQueue.async { [weak self, sendableBuffer] in
            autoreleasepool {
                guard let self = self else { return }
                
                Task { [weak self, sendableBuffer] in
                    guard let self = self else { return }
                    
                    // Set AR mode for ARKit
                    await MainActor.run {
                        self.ocrService.arMode = .arkit
                    }
                    
                    // Use OCRService for consistent OCR quality
                    // Pass isARFrame=true to handle rotation
                    // Process buffer directly using the wrapped value
                    await self.ocrService.processBuffer(sendableBuffer.value, excludeRegions: [], isARFrame: true)
                    
                    // Get results and immediately process
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        
                        let texts = self.ocrService.recognizedTexts
                        
                        if !texts.isEmpty {
                            Logger.shared.log(.info, "ARKit OCR: Frame \(self.frameCount) detected \(texts.count) texts")
                            // Log first few texts for debugging
                            for (index, text) in texts.prefix(3).enumerated() {
                                Logger.shared.log(.debug, "  Text \(index): '\(text.text)' conf: \(text.confidence)")
                            }
                        } else if self.frameCount % 10 == 0 {
                            Logger.shared.log(.debug, "ARKit OCR: Frame \(self.frameCount) - no texts detected")
                        }
                        
                        // Call callback if exists
                        self.onTextDetected?(texts)
                        
                        // Clear processing flag
                        self.isProcessing = false
                    }
                }
            } // autoreleasepool drains here, releasing memory
        }
    }
    
    func session(_ session: ARSession, didFailWithError error: Error) {
        Logger.shared.log(.error, "ARKit session error: \(error.localizedDescription)")
        isProcessing = false
        lastProcessedTime = 0
    }
    
    func sessionWasInterrupted(_ session: ARSession) {
        Logger.shared.log(.warning, "ARKit session interrupted")
        isProcessing = false
        lastProcessedTime = 0
    }
    
    func sessionInterruptionEnded(_ session: ARSession) {
        Logger.shared.log(.info, "ARKit session interruption ended")
        lastProcessedTime = 0
        isProcessing = false
        
        // Restart session if needed
        if session.currentFrame == nil {
            Logger.shared.log(.warning, "ARKit: No current frame after interruption, restarting session")
            let configuration = ARWorldTrackingConfiguration()
            configuration.planeDetection = []
            configuration.isAutoFocusEnabled = true
            session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else if let frame = session.currentFrame {
            Logger.shared.log(.info, "ARKit: Session resumed, camera tracking: \(frame.camera.trackingState)")
        }
    }
    
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        var message = "ARKit tracking state: "
        switch camera.trackingState {
        case .notAvailable:
            message += "Not Available"
        case .limited(let reason):
            message += "Limited - "
            switch reason {
            case .excessiveMotion:
                message += "Excessive Motion"
            case .insufficientFeatures:
                message += "Insufficient Features"
            case .initializing:
                message += "Initializing"
            case .relocalizing:
                message += "Relocalizing"
            @unknown default:
                message += "Unknown"
            }
        case .normal:
            message += "Normal"
        }
        Logger.shared.log(.info, message)
    }
    
    deinit {
        isProcessing = false
    }
    
    // MARK: - Helper Methods
    
    private func copyPixelBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        
        var copiedBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            nil,
            &copiedBuffer
        )
        
        guard status == kCVReturnSuccess, let outputBuffer = copiedBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(outputBuffer, [])
        
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(outputBuffer, [])
        }
        
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let outputAddress = CVPixelBufferGetBaseAddress(outputBuffer)
        
        if let baseAddress = baseAddress, let outputAddress = outputAddress {
            memcpy(outputAddress, baseAddress, height * bytesPerRow)
        }
        
        return outputBuffer
    }
    
    // MARK: - Cleanup
    
    func cleanup() {
        // Cancel any pending processing
        isProcessing = false
        frameCount = 0
        lastProcessedTime = 0
        
        // Clear any pending operations on the queue
        processingQueue.async { [weak self] in
            // Ensure queue is cleared
            self?.isProcessing = false
        }
        
        Logger.shared.log(.info, "ARFrameProcessor: Cleaned up and reset")
    }
}