//
//  MotionTracker.swift
//  ViewLingo-Cam
//
//  Real-time device motion tracking for AR overlay compensation
//

import Foundation
import CoreMotion
import CoreGraphics
import UIKit

/// Tracks device motion to compensate AR overlay positions in real-time
@MainActor
class MotionTracker: ObservableObject {
    // MARK: - Published Properties
    
    @Published var isTracking = false
    @Published var motionOffset = CGPoint.zero
    @Published var rotationAngle: Double = 0
    
    // MARK: - Private Properties
    
    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()
    
    // Calibration and filtering
    private var baseRotation: CMRotationRate?
    private var lastUpdateTime: TimeInterval = 0
    private let updateInterval: TimeInterval = 1.0 / 60.0  // 60Hz update rate
    
    // Kalman filter for noise reduction
    private var velocityX: Double = 0
    private var velocityY: Double = 0
    private let alpha: Double = 0.8  // Low-pass filter coefficient
    
    // Motion sensitivity
    private let rotationSensitivity: Double = 1.0
    private let translationSensitivity: Double = 100.0
    
    // Screen dimensions for normalization
    private var screenSize = UIScreen.main.bounds.size
    
    // MARK: - Initialization
    
    init() {
        motionQueue.maxConcurrentOperationCount = 1
        motionQueue.name = "com.viewlingo.motion"
    }
    
    // MARK: - Public Methods
    
    /// Start tracking device motion
    func startTracking() {
        guard !isTracking else { return }
        
        guard motionManager.isDeviceMotionAvailable else {
            Logger.shared.log(.warning, "Device motion not available")
            return
        }
        
        isTracking = true
        motionManager.deviceMotionUpdateInterval = updateInterval
        
        // Start device motion updates
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, error in
            guard let self = self, let motion = motion else {
                if let error = error {
                    Logger.shared.log(.error, "Motion tracking error: \(error)")
                }
                return
            }
            
            Task { @MainActor in
                self.processMotionData(motion)
            }
        }
        
        Logger.shared.log(.info, "Motion tracking started at 60Hz")
    }
    
    /// Stop tracking device motion
    func stopTracking() {
        guard isTracking else { return }
        
        motionManager.stopDeviceMotionUpdates()
        isTracking = false
        
        // Reset values
        motionOffset = .zero
        rotationAngle = 0
        velocityX = 0
        velocityY = 0
        
        Logger.shared.log(.info, "Motion tracking stopped")
    }
    
    /// Get predicted position for a bounding box based on motion
    func getPredictedPosition(for box: CGRect, deltaTime: TimeInterval = 0.016) -> CGRect {
        guard isTracking else { return box }
        
        // Calculate predicted offset based on velocity
        let predictedX = motionOffset.x + CGFloat(velocityX * deltaTime)
        let predictedY = motionOffset.y + CGFloat(velocityY * deltaTime)
        
        // Apply rotation transformation
        let centerX = box.midX
        let centerY = box.midY
        let angle = CGFloat(rotationAngle * deltaTime)
        
        // Rotate around center
        let cosAngle = cos(angle)
        let sinAngle = sin(angle)
        
        var predictedBox = box
        
        // Apply translation
        predictedBox.origin.x += predictedX
        predictedBox.origin.y += predictedY
        
        // Apply rotation (simplified for small angles)
        if abs(angle) > 0.001 {
            let newX = centerX + (box.origin.x - centerX) * cosAngle - (box.origin.y - centerY) * sinAngle
            let newY = centerY + (box.origin.x - centerX) * sinAngle + (box.origin.y - centerY) * cosAngle
            predictedBox.origin.x = newX
            predictedBox.origin.y = newY
        }
        
        return predictedBox
    }
    
    /// Reset motion tracking calibration
    func resetCalibration() {
        baseRotation = nil
        motionOffset = .zero
        rotationAngle = 0
        velocityX = 0
        velocityY = 0
        Logger.shared.log(.info, "Motion tracking calibration reset")
    }
    
    // MARK: - Private Methods
    
    private func processMotionData(_ motion: CMDeviceMotion) {
        let currentTime = motion.timestamp
        let deltaTime = lastUpdateTime > 0 ? currentTime - lastUpdateTime : updateInterval
        lastUpdateTime = currentTime
        
        // Get rotation rate (gyroscope)
        let rotation = motion.rotationRate
        
        // Calibrate on first reading
        if baseRotation == nil {
            baseRotation = rotation
        }
        
        // Calculate relative rotation
        let relativeRotationX = rotation.x - (baseRotation?.x ?? 0)
        let relativeRotationY = rotation.y - (baseRotation?.y ?? 0)
        let relativeRotationZ = rotation.z - (baseRotation?.z ?? 0)
        
        // Convert rotation to screen space movement
        // Phone rotation around Y-axis = horizontal screen movement
        // Phone rotation around X-axis = vertical screen movement
        let rawOffsetX = -relativeRotationY * translationSensitivity * deltaTime
        let rawOffsetY = relativeRotationX * translationSensitivity * deltaTime
        
        // Apply low-pass filter to reduce noise
        velocityX = alpha * velocityX + (1 - alpha) * rawOffsetX / deltaTime
        velocityY = alpha * velocityY + (1 - alpha) * rawOffsetY / deltaTime
        
        // Update motion offset (normalized to screen size)
        motionOffset.x = CGFloat(velocityX * deltaTime) / screenSize.width
        motionOffset.y = CGFloat(velocityY * deltaTime) / screenSize.height
        
        // Update rotation angle (Z-axis rotation)
        rotationAngle = relativeRotationZ * rotationSensitivity
        
        // Get acceleration for additional motion detection
        let userAcceleration = motion.userAcceleration
        
        // Detect significant motion (shake or quick movement)
        let accelerationMagnitude = sqrt(
            userAcceleration.x * userAcceleration.x +
            userAcceleration.y * userAcceleration.y +
            userAcceleration.z * userAcceleration.z
        )
        
        // If significant acceleration detected, increase prediction
        if accelerationMagnitude > 0.5 {
            let boostFactor = min(2.0, 1.0 + accelerationMagnitude)
            velocityX *= boostFactor
            velocityY *= boostFactor
        }
    }
    
    /// Update screen size for normalization
    func updateScreenSize(_ size: CGSize) {
        screenSize = size
    }
}

// MARK: - Motion Prediction

extension MotionTracker {
    /// Predict multiple frames ahead for smoother tracking
    func getPredictedPath(for box: CGRect, frames: Int = 3) -> [CGRect] {
        var predictions: [CGRect] = []
        var currentBox = box
        let frameTime = 1.0 / 60.0  // 60 FPS
        
        for _ in 0..<frames {
            currentBox = getPredictedPosition(for: currentBox, deltaTime: frameTime)
            predictions.append(currentBox)
        }
        
        return predictions
    }
    
    /// Get interpolated position between current and predicted
    func getInterpolatedPosition(for box: CGRect, factor: CGFloat = 0.5) -> CGRect {
        let predicted = getPredictedPosition(for: box)
        
        var interpolated = box
        interpolated.origin.x = box.origin.x + (predicted.origin.x - box.origin.x) * factor
        interpolated.origin.y = box.origin.y + (predicted.origin.y - box.origin.y) * factor
        
        return interpolated
    }
}