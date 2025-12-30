//
//  ARKitTracker.swift
//  ViewLingo-Cam
//
//  ARKit-based 3D tracking for enhanced AR experience
//

import Foundation
import ARKit
import RealityKit
import Combine

@available(iOS 18.0, *)
class ARKitTracker: NSObject, ObservableObject {
    // MARK: - Published Properties
    @Published var arAnchors: [TextAnchor] = []
    @Published var isTracking = false
    @Published var trackingQuality: ARCamera.TrackingState.Reason?
    
    // MARK: - Private Properties
    private var arSession: ARSession?
    private var arView: ARView?
    private var cancellables = Set<AnyCancellable>()
    private let processingQueue = DispatchQueue(label: "com.viewlingo.arkit", qos: .userInitiated)
    
    // MARK: - Types
    struct TextAnchor: Identifiable {
        let id = UUID()
        let text: String
        let translation: String
        let anchor: ARAnchor
        var worldPosition: simd_float3
        var entity: ModelEntity?
        let boundingBox: CGRect
        
        mutating func updateEntity(_ entity: ModelEntity) {
            self.entity = entity
        }
    }
    
    // MARK: - Initialization
    override init() {
        super.init()
    }
    
    // MARK: - Public Methods
    
    func setupARSession() {
        Logger.shared.log(.info, "ARKit mode: Setting up AR session")
        
        // Check if ARKit is supported
        guard ARWorldTrackingConfiguration.isSupported else {
            Logger.shared.log(.error, "ARKit mode: ARWorldTrackingConfiguration not supported")
            isTracking = false
            return
        }
        
        // Create AR configuration
        let configuration = ARWorldTrackingConfiguration()
        
        // Optimized configuration for text overlay
        configuration.planeDetection = []  // No plane detection needed
        configuration.environmentTexturing = .none
        configuration.isLightEstimationEnabled = false
        configuration.frameSemantics = []  // No additional processing
        configuration.isAutoFocusEnabled = true  // Keep focus for text clarity
        
        // Set video format for best performance
        if let format = ARWorldTrackingConfiguration.supportedVideoFormats.first(where: { format in
            format.imageResolution.width == 1920  // 1080p for good OCR
        }) {
            configuration.videoFormat = format
        }
        
        // Create and configure AR session
        arSession = ARSession()
        // Don't set delegate here - let ARKitOverlayView set the appropriate delegate
        // arSession?.delegate = self  // REMOVED to prevent delegate conflicts
        arSession?.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        
        isTracking = true
        Logger.shared.log(.info, "ARKit mode: Session started successfully (simplified mode)")
    }
    
    func stopARSession() {
        Logger.shared.log(.info, "Stopping ARKit session")
        
        arSession?.pause()
        arSession = nil
        arView = nil
        arAnchors.removeAll()
        isTracking = false
    }
    
    func setARView(_ view: ARView) {
        self.arView = view
        // Only set session if we have one configured
        if let arSession = arSession {
            view.session = arSession
            Logger.shared.log(.info, "ARKit mode: Connected ARView to existing session")
        } else {
            Logger.shared.log(.warning, "ARKit mode: No session available when setting ARView")
        }
    }
    
    func addTextAnchor(at position: CGPoint, text: String, translation: String, boundingBox: CGRect) {
        guard arView != nil else {
            Logger.shared.log(.warning, "ARKit mode: ARView not set, cannot add anchor")
            return
        }
        
        // Skip raycast and use simple 3D positioning
        // This avoids the plane detection requirement
        Logger.shared.log(.debug, "ARKit mode: Adding text anchor for '\(text)' without plane detection")
        
        // Create a simple anchor at a fixed distance
        let distance: Float = 1.0
        let x = Float((position.x / UIScreen.main.bounds.width - 0.5) * 2) * 0.5
        let y = Float((0.5 - position.y / UIScreen.main.bounds.height) * 2) * 0.3
        
        // Create transform matrix for position
        var transform = matrix_identity_float4x4
        transform.columns.3.x = x
        transform.columns.3.y = y
        transform.columns.3.z = -distance
        
        let anchor = ARAnchor(transform: transform)
        arSession?.add(anchor: anchor)
        
        // Create text anchor
        let textAnchor = TextAnchor(
            text: text,
            translation: translation,
            anchor: anchor,
            worldPosition: SIMD3<Float>(x, y, -distance),
            boundingBox: boundingBox
        )
        
        // Add to tracked anchors without triggering view updates
        arAnchors.append(textAnchor)
        
        Logger.shared.log(.info, "ARKit mode: Added anchor for '\(text)' at (\(x), \(y), \(-distance))")
    }
    
    func updateTextAnchors(with trackedTexts: [TrackedText]) {
        // This method is intentionally simplified to avoid update loops
        // Only log the request, don't actually update
        Logger.shared.log(.debug, "ARKit mode: Update request for \(trackedTexts.count) texts (ignored to prevent loops)")
    }
    
    // MARK: - Private Methods
    
    private func createTextEntity(for textAnchor: TextAnchor) {
        guard let arView = arView else { return }
        
        Task { @MainActor in
            // Create text mesh
            let textMesh = MeshResource.generateText(
                textAnchor.translation,
                extrusionDepth: 0.005,
                font: .systemFont(ofSize: 0.03)
            )
            
            // Create material with translucent blue
            var material = SimpleMaterial()
            material.color = .init(tint: .systemBlue.withAlphaComponent(0.9))
            material.metallic = 0.1
            material.roughness = 0.5
            
            // Create model entity
            let textEntity = ModelEntity(mesh: textMesh, materials: [material])
            
            // Add background plane
            let planeMesh = MeshResource.generatePlane(
                width: 0.2,
                height: 0.05,
                cornerRadius: 0.005
            )
            var planeMaterial = SimpleMaterial()
            planeMaterial.color = .init(tint: .white.withAlphaComponent(0.8))
            let planeEntity = ModelEntity(mesh: planeMesh, materials: [planeMaterial])
            planeEntity.position.z = -0.01 // Place slightly behind text
            
            // Create anchor entity and add children
            let anchorEntity = AnchorEntity(world: textAnchor.worldPosition)
            anchorEntity.addChild(planeEntity)
            anchorEntity.addChild(textEntity)
            
            // Add to AR scene
            arView.scene.addAnchor(anchorEntity)
            
            // Update text anchor with entity reference
            if let index = self.arAnchors.firstIndex(where: { $0.id == textAnchor.id }) {
                self.arAnchors[index].updateEntity(textEntity)
            }
        }
    }
    
    private func updateEntityPosition(_ entity: ModelEntity, for boundingBox: CGRect) {
        guard let arView = arView else { return }
        
        // Convert screen coordinates to AR coordinates
        let screenPosition = CGPoint(
            x: boundingBox.midX * UIScreen.main.bounds.width,
            y: boundingBox.midY * UIScreen.main.bounds.height
        )
        
        // Perform raycast to update position
        let results = arView.raycast(from: screenPosition, allowing: .estimatedPlane, alignment: .any)
        
        if let firstResult = results.first {
            // Update entity position with smooth animation
            var transform = entity.transform
            transform.translation = firstResult.worldTransform.columns.3.xyz
            entity.move(to: transform, relativeTo: nil, duration: 0.3)
        }
    }
}

// MARK: - ARSessionDelegate methods removed
// Delegate is now handled by ARFrameProcessor for proper frame management

// MARK: - Extensions

extension simd_float4x4 {
    var translation: simd_float3 {
        return simd_float3(columns.3.x, columns.3.y, columns.3.z)
    }
}

extension simd_float4 {
    var xyz: simd_float3 {
        return simd_float3(x, y, z)
    }
}