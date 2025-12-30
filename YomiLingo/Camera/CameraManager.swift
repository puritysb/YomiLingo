//
//  CameraManager.swift
//  ViewLingo-Cam
//
//  Manages AVCaptureSession for camera
//

@preconcurrency import AVFoundation
import UIKit
import Combine

@MainActor
class CameraManager: NSObject, ObservableObject {
    // MARK: - Published Properties
    
    @Published var isRunning = false
    @Published var isAuthorized = false
    @Published var isPaused = false  // Track paused state
    @Published var currentFrame: CVPixelBuffer?
    @Published var frameUpdateCount: Int = 0  // Trigger for frame updates
    @Published var error: Error?
    
    // MARK: - Private Properties
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.viewlingo.camera")
    private let frameProcessingQueue = DispatchQueue(label: "com.viewlingo.frameProcessing", qos: .userInitiated)
    
    private let frameCounter = AtomicInt()
    // Frame skipping removed - camera now runs at 15fps, process all frames
    
    // Keep track of dropped frames for monitoring
    private var droppedFrameCount = 0
    private var lastDroppedFrameLog = Date()
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        checkAuthorization()
    }
    
    // MARK: - Authorization
    
    @MainActor
    func checkAndRequestAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            Logger.shared.logCamera("Camera already authorized")
            return true
            
        case .notDetermined:
            Logger.shared.logCamera("Camera authorization not determined, requesting...")
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
            if granted {
                Logger.shared.logCamera("Camera access granted")
            } else {
                Logger.shared.logCamera("Camera access denied by user")
            }
            return granted
            
        case .denied, .restricted:
            isAuthorized = false
            Logger.shared.logCamera("Camera access denied or restricted")
            return false
            
        @unknown default:
            isAuthorized = false
            Logger.shared.logCamera("Camera access unknown status")
            return false
        }
    }
    
    private func checkAuthorization() {
        // Legacy method for compatibility - now just checks status without requesting
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            Logger.shared.logCamera("Camera authorized")
        case .notDetermined:
            isAuthorized = false
            Logger.shared.logCamera("Camera authorization not determined")
        case .denied, .restricted:
            isAuthorized = false
            Logger.shared.logCamera("Camera access denied or restricted")
        @unknown default:
            isAuthorized = false
        }
    }
    
    // MARK: - Session Configuration
    
    @MainActor
    func configureCaptureSession() async {
        await configureSessionInternal()
    }
    
    @MainActor
    private func configureSessionInternal() async {
        Logger.shared.logCamera("Configuring capture session")
        
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        
        // Set session preset based on device type
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        if isIPad {
            // Use a more compatible preset for iPad
            if captureSession.canSetSessionPreset(.hd1920x1080) {
                captureSession.sessionPreset = .hd1920x1080
                Logger.shared.logCamera("Using HD preset for iPad")
            } else if captureSession.canSetSessionPreset(.hd1280x720) {
                captureSession.sessionPreset = .hd1280x720
                Logger.shared.logCamera("Using 720p preset for iPad")
            } else {
                captureSession.sessionPreset = .medium
                Logger.shared.logCamera("Using medium preset for iPad")
            }
        } else {
            // iPhone configuration
            if captureSession.canSetSessionPreset(.high) {
                captureSession.sessionPreset = .high
            }
        }
        
        // Add video input - handle iPad camera differences
        let videoDevice: AVCaptureDevice?
        if isIPad {
            // iPad might have different camera configurations
            videoDevice = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ) ?? AVCaptureDevice.default(for: .video)
        } else {
            videoDevice = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            )
        }
        
        guard let device = videoDevice else {
            Logger.shared.log(.error, "Failed to get video device")
            return
        }
        
        do {
            // Configure device for 15fps before creating input
            try device.lockForConfiguration()
            
            // Set frame rate to 15fps for better performance and battery life
            // This reduces unnecessary processing while maintaining smooth experience
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15) // 15fps
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15) // 15fps
            
            device.unlockForConfiguration()
            Logger.shared.logCamera("Set camera to 15fps for optimal performance")
            
            let videoInput = try AVCaptureDeviceInput(device: device)
            
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
                Logger.shared.logCamera("Added video input")
            }
        } catch {
            Logger.shared.log(.error, "Failed to create video input: \(error)")
            Task { @MainActor in
                self.error = error
            }
            return
        }
        
        // Configure video output
        videoOutput.setSampleBufferDelegate(self, queue: frameProcessingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            Logger.shared.logCamera("Added video output")
        }
        
        // Set video orientation
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
    
    // MARK: - Session Control
    
    func startSession() {
        guard isAuthorized else {
            Logger.shared.log(.warning, "Cannot start camera: not authorized")
            return
        }
        
        let session = self.captureSession  // Capture before async
        sessionQueue.async { [weak self, session] in
            guard let self = self else { return }
            
            // Start running on background thread to prevent UI blocking
            if !session.isRunning {
                session.startRunning()
                
                Task { @MainActor in
                    self.isRunning = true
                    self.isPaused = false
                    Logger.shared.logCamera("Session started")
                }
            }
        }
    }
    
    @MainActor
    func stopSessionImmediately() {
        // Immediately stop on main thread for instant response
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
        
        isRunning = false
        isPaused = false
        
        currentFrame = nil
        
        Logger.shared.logCamera("Session stopped immediately")
        
        // Clean up on background queue
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            Task { @MainActor in
                self.captureSession.beginConfiguration()
                self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
                self.captureSession.outputs.forEach { self.captureSession.removeOutput($0) }
                self.captureSession.commitConfiguration()
                
                Logger.shared.logCamera("Session cleanup completed")
            }
        }
    }
    
    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            Task { @MainActor in
                if self.captureSession.isRunning {
                    self.captureSession.stopRunning()
                }
                
                // Always clear inputs and outputs for clean state
                self.captureSession.beginConfiguration()
                self.captureSession.inputs.forEach { self.captureSession.removeInput($0) }
                self.captureSession.outputs.forEach { self.captureSession.removeOutput($0) }
                self.captureSession.commitConfiguration()
                
                self.isRunning = false
                self.isPaused = false
                self.currentFrame = nil
                Logger.shared.logCamera("Session stopped and cleaned up")
            }
        }
    }
    
    func pauseSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            Task { @MainActor in
                if self.captureSession.isRunning {
                    self.captureSession.stopRunning()
                    self.isRunning = false
                    self.isPaused = true
                    Logger.shared.logCamera("Session paused")
                }
            }
        }
    }
    
    func resumeSession() {
        guard isAuthorized else {
            Logger.shared.log(.warning, "Cannot resume camera: not authorized")
            return
        }
        
        let isPausedState = self.isPaused  // Capture before async
        let session = self.captureSession  // Capture before async
        sessionQueue.async { [weak self, isPausedState, session] in
            guard let self = self else { return }
            
            if isPausedState && !session.isRunning {
                // Re-add inputs and outputs if needed
                if session.inputs.isEmpty || session.outputs.isEmpty {
                    // Reconfigure if session was cleaned
                    Task { @MainActor in
                        await self.configureCaptureSession()
                        // After configuration, start the session
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.startSession()
                        }
                    }
                    return
                }
                
                // Start running on background thread to prevent UI blocking
                session.startRunning()
                
                Task { @MainActor in
                    self.isRunning = true
                    self.isPaused = false
                    Logger.shared.logCamera("Session resumed")
                }
            }
        }
    }
    
    // MARK: - Focus Control
    
    func focus(at point: CGPoint) {
        sessionQueue.async {
            Task { @MainActor [weak self] in
                guard let self = self,
                      let device = self.getCurrentDevice() else { return }
            
            do {
                try device.lockForConfiguration()
                
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                
                device.unlockForConfiguration()
                
                Logger.shared.logCamera("Focus set at: \(point)")
            } catch {
                Logger.shared.log(.error, "Failed to set focus: \(error)")
            }
            }
        }
    }
    
    // MARK: - Helper Methods
    
    @MainActor
    private func getCurrentDevice() -> AVCaptureDevice? {
        return (captureSession.inputs.first as? AVCaptureDeviceInput)?.device
    }
    
    func getCaptureSession() -> AVCaptureSession {
        return captureSession
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, 
                      didOutput sampleBuffer: CMSampleBuffer,
                      from connection: AVCaptureConnection) {
        // Process all frames - camera is already at 15fps
        let _ = frameCounter.increment()
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        
        Task { @MainActor in
            self.currentFrame = pixelBuffer
            self.frameUpdateCount += 1  // Increment to trigger onChange
        }
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                      didDrop sampleBuffer: CMSampleBuffer,
                      from connection: AVCaptureConnection) {
        // Only log dropped frames occasionally to avoid spam
        // Log summary every 5 seconds if frames are being dropped
        Task { @MainActor in
            self.droppedFrameCount += 1
            
            let now = Date()
            if now.timeIntervalSince(self.lastDroppedFrameLog) > 5.0 && self.droppedFrameCount > 0 {
                Logger.shared.log(.debug, "Dropped \(self.droppedFrameCount) frames in last 5 seconds")
                self.droppedFrameCount = 0
                self.lastDroppedFrameLog = now
            }
        }
    }
}
