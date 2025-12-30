//
//  VisionTracker.swift
//  ViewLingo-Cam
//
//  Vision-based object tracking for smooth AR overlay updates
//

import Foundation
import Vision
@preconcurrency import CoreImage
@preconcurrency import AVFoundation

/// Tracks text regions using Vision framework's object tracking
@MainActor
class VisionTracker: ObservableObject {
    
    /// Represents a tracked object with Vision framework
    struct TrackedObject {
        let id: UUID
        let initialBox: CGRect
        var currentBox: CGRect
        var lastObservation: VNDetectedObjectObservation?
        var confidence: Float
        var isTracking: Bool
        
        init(box: CGRect) {
            self.id = UUID()
            self.initialBox = box
            self.currentBox = box
            self.confidence = 1.0
            self.isTracking = true
        }
    }
    
    // MARK: - Published Properties
    
    @Published var trackedObjects: [UUID: TrackedObject] = [:]
    @Published var isProcessing = false
    
    // MARK: - Private Properties
    
    private var trackingRequests: [UUID: VNTrackObjectRequest] = [:]
    private let processingQueue = DispatchQueue(label: "com.viewlingo.visiontracker", qos: .userInitiated)
    private var lastProcessedBuffer: CVPixelBuffer?
    private var sequenceRequestHandler: VNSequenceRequestHandler?
    
    // Tracking parameters
    private let minimumConfidence: Float = 0.3
    private let trackingLevel: VNRequestTrackingLevel = .fast  // Fast for real-time
    
    // MARK: - Public Methods
    
    /// Start tracking a new text region
    func startTracking(box: CGRect, in buffer: CVPixelBuffer) -> UUID? {
        // Create initial observation
        let observation = VNDetectedObjectObservation(boundingBox: box)
        
        // Create tracking request
        let request = VNTrackObjectRequest(detectedObjectObservation: observation)
        request.trackingLevel = trackingLevel
        
        // Create tracked object
        var trackedObject = TrackedObject(box: box)
        trackedObject.lastObservation = observation
        
        // Store
        let objectId = trackedObject.id
        trackedObjects[objectId] = trackedObject
        trackingRequests[objectId] = request
        
        Logger.shared.log(.debug, "Started tracking object at \(box)")
        
        return objectId
    }
    
    /// Update tracking for all objects with new frame
    func updateTracking(with buffer: CVPixelBuffer) async {
        guard !trackedObjects.isEmpty else { return }
        
        // Wrap buffer in UnsafeSendable before capturing in async closure
        let sendableBuffer = UnsafeSendable(buffer)
        
        await withCheckedContinuation { continuation in
            processingQueue.async { [weak self, sendableBuffer] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                
                // Process on main actor
                Task { @MainActor [sendableBuffer] in
                    // Create or reuse sequence handler
                    if self.sequenceRequestHandler == nil {
                        self.sequenceRequestHandler = VNSequenceRequestHandler()
                    }
                    
                    // Prepare all tracking requests
                    var requests: [VNTrackObjectRequest] = []
                    var requestToId: [VNRequest: UUID] = [:]
                    
                    for (objectId, request) in self.trackingRequests {
                        guard let object = self.trackedObjects[objectId],
                              object.isTracking else { continue }
                        
                        request.isLastFrame = false  // Continue tracking
                        requests.append(request)
                        requestToId[request] = objectId
                    }
                    
                    guard !requests.isEmpty else {
                        continuation.resume()
                        return
                    }
                    
                    // Perform tracking
                    do {
                        // Use sendable buffer value to avoid warnings
                        try self.sequenceRequestHandler?.perform(requests, on: sendableBuffer.value)
                    
                        // Process results
                        for request in requests {
                            guard let objectId = requestToId[request],
                                  var trackedObject = self.trackedObjects[objectId] else { continue }
                            
                            if let results = request.results as? [VNDetectedObjectObservation],
                               let observation = results.first {
                                
                                // Update tracked object
                                trackedObject.currentBox = observation.boundingBox
                                trackedObject.confidence = observation.confidence
                                trackedObject.lastObservation = observation
                                
                                // Check confidence threshold
                                if observation.confidence < self.minimumConfidence {
                                    trackedObject.isTracking = false
                                    Logger.shared.log(.debug, "Lost tracking for object \(objectId): low confidence \(observation.confidence)")
                                } else {
                                    // Update tracking request for next frame
                                    self.trackingRequests[objectId] = VNTrackObjectRequest(detectedObjectObservation: observation)
                                    self.trackingRequests[objectId]?.trackingLevel = self.trackingLevel
                                }
                                
                                self.trackedObjects[objectId] = trackedObject
                            } else {
                                // Lost tracking
                                trackedObject.isTracking = false
                                self.trackedObjects[objectId] = trackedObject
                                Logger.shared.log(.debug, "Lost tracking for object \(objectId): no observation")
                            }
                        }
                        
                        self.lastProcessedBuffer = sendableBuffer.value
                        
                    } catch {
                        Logger.shared.log(.error, "Vision tracking error: \(error)")
                    }
                    
                    continuation.resume()
                }
            }
        }
    }
    
    /// Stop tracking a specific object
    func stopTracking(objectId: UUID) {
        trackedObjects.removeValue(forKey: objectId)
        trackingRequests.removeValue(forKey: objectId)
        Logger.shared.log(.debug, "Stopped tracking object \(objectId)")
    }
    
    /// Stop tracking all objects
    func stopAllTracking() {
        trackedObjects.removeAll()
        trackingRequests.removeAll()
        sequenceRequestHandler = nil
        Logger.shared.log(.info, "Stopped all vision tracking")
    }
    
    /// Get current position for a tracked object
    func getCurrentPosition(for objectId: UUID) -> CGRect? {
        return trackedObjects[objectId]?.currentBox
    }
    
    /// Get all currently tracked positions
    func getAllTrackedPositions() -> [UUID: CGRect] {
        var positions: [UUID: CGRect] = [:]
        for (id, object) in trackedObjects where object.isTracking {
            positions[id] = object.currentBox
        }
        return positions
    }
    
    /// Check if an object is still being tracked
    func isTracking(objectId: UUID) -> Bool {
        return trackedObjects[objectId]?.isTracking ?? false
    }
    
    /// Update tracked objects from OCR results
    func syncWithOCRResults(_ ocrBoxes: [CGRect]) {
        // Remove objects that are no longer detected
        var objectsToRemove: [UUID] = []
        
        for (objectId, trackedObject) in trackedObjects {
            var foundMatch = false
            
            for ocrBox in ocrBoxes {
                let iou = calculateIoU(trackedObject.currentBox, ocrBox)
                if iou > 0.5 {  // 50% overlap threshold
                    foundMatch = true
                    break
                }
            }
            
            if !foundMatch && trackedObject.isTracking {
                objectsToRemove.append(objectId)
            }
        }
        
        // Remove unmatched objects
        for objectId in objectsToRemove {
            stopTracking(objectId: objectId)
        }
        
        // Add new objects not being tracked
        for ocrBox in ocrBoxes {
            var isNewObject = true
            
            for trackedObject in trackedObjects.values {
                let iou = calculateIoU(trackedObject.currentBox, ocrBox)
                if iou > 0.5 {
                    isNewObject = false
                    break
                }
            }
            
            if isNewObject, let buffer = lastProcessedBuffer {
                _ = startTracking(box: ocrBox, in: buffer)
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func calculateIoU(_ box1: CGRect, _ box2: CGRect) -> Double {
        let intersection = box1.intersection(box2)
        guard !intersection.isNull else { return 0 }
        
        let intersectionArea = intersection.width * intersection.height
        let unionArea = (box1.width * box1.height) + (box2.width * box2.height) - intersectionArea
        
        return Double(intersectionArea / unionArea)
    }
}

// MARK: - Optical Flow Extension

extension VisionTracker {
    /// Use optical flow for smoother tracking between frames (simplified version)
    func performOpticalFlowTracking(from previousBuffer: CVPixelBuffer, to currentBuffer: CVPixelBuffer) async -> [UUID: CGVector] {
        var flowVectors: [UUID: CGVector] = [:]
        
        // Note: VNGenerateOpticalFlowRequest requires iOS 14+ and proper initialization
        // For now, return estimated flow based on position changes
        for (objectId, object) in trackedObjects where object.isTracking {
            // Simple flow estimation based on position change
            if let prevBox = object.lastObservation?.boundingBox {
                let dx = object.currentBox.midX - prevBox.midX
                let dy = object.currentBox.midY - prevBox.midY
                flowVectors[objectId] = CGVector(dx: dx, dy: dy)
            }
        }
        
        return flowVectors
    }
    
    /// Perform actual optical flow if needed (requires proper setup)
    private func performRealOpticalFlow(from previousBuffer: CVPixelBuffer, to currentBuffer: CVPixelBuffer) async -> [UUID: CGVector] {
        let flowVectors: [UUID: CGVector] = [:]
        
        // Optical flow implementation would go here if needed
        // This requires proper frame-to-frame tracking setup
        
        /*
        await withCheckedContinuation { continuation in
            processingQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: flowVectors)
                    return
                }
                
                // Optical flow processing would go here
                // VNGenerateOpticalFlowRequest needs proper initialization with two frames
                
            }
        }
        */
        
        return flowVectors
    }
}