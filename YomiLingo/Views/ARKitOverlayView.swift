//
//  ARKitOverlayView.swift
//  ViewLingo-Cam
//
//  ARKit-based 3D overlay for advanced AR translation
//

import SwiftUI
import ARKit
import RealityKit

@available(iOS 18.0, *)
struct ARKitOverlayView: UIViewRepresentable {
    let translationCoordinator: TranslationCoordinator  // Pass from parent instead of creating new
    @Binding var arkitCoordinator: Coordinator?  // Binding to expose coordinator to parent
    @EnvironmentObject var appState: AppState
    @State private var use2DOverlay = false  // Use 3D ARKit mode
    
    // ARTracker should be managed externally to avoid StateObject issues
    private let arTracker = ARKitTracker()
    private let textManager = AR3DTextManager()
    @State private var arSession: ARSession?
    @State private var isSessionRunning = false
    
    init(translationCoordinator: TranslationCoordinator, arkitCoordinator: Binding<Coordinator?>) {
        self.translationCoordinator = translationCoordinator
        self._arkitCoordinator = arkitCoordinator
    }
    private let textTracker = TextTracker()  // Own text tracker for ARKit mode
    
    func makeUIView(context: Context) -> ARView {
        Logger.shared.log(.info, "ARKit mode: Initializing AR view (2D mode: \(use2DOverlay))")
        
        // Set AR mode for text tracker
        textTracker.arMode = .arkit
        
        let arView = ARView(frame: .zero)
        
        // Configure AR view for performance
        arView.automaticallyConfigureSession = false
        arView.renderOptions = [
            .disablePersonOcclusion,
            .disableDepthOfField,
            .disableMotionBlur,
            .disableHDR
        ]
        
        // Enable camera feed background - CRITICAL for seeing the real world
        arView.environment.background = .cameraFeed()
        Logger.shared.log(.info, "ARKit mode: Camera feed background enabled")
        
        // Check if ARKit is available
        guard ARWorldTrackingConfiguration.isSupported else {
            Logger.shared.log(.error, "ARKit mode: ARWorldTrackingConfiguration not supported on this device")
            return arView
        }
        
        // Setup AR session immediately - camera should already be stopped from settings
        arTracker.setupARSession()
        arTracker.setARView(arView)
        Logger.shared.log(.info, "ARKit mode: Session setup completed")
        
        // Store the session for control
        context.coordinator.arSession = arView.session
        
        // Set up frame processor callback using coordinator's instance
        context.coordinator.frameProcessor.onTextDetected = { detectedTexts in
            Logger.shared.log(.debug, "ARKitOverlayView: Frame processor callback triggered with \(detectedTexts.count) texts")
            context.coordinator.processDetectedTexts(detectedTexts, in: arView)
        }
        
        // Set initial Live mode state
        context.coordinator.frameProcessor.isLiveModeEnabled = appState.isLiveTranslationEnabled == true
        Logger.shared.log(.info, "ARKitOverlayView: Initial Live mode state: \(context.coordinator.frameProcessor.isLiveModeEnabled)")
        
        // Store ARSession reference in coordinator for manual capture
        context.coordinator.arSession = arView.session
        
        // Expose coordinator to parent via binding - defer to avoid SwiftUI state modification warning
        DispatchQueue.main.async {
            arkitCoordinator = context.coordinator
        }
        
        // Set frame processor as delegate - use coordinator's instance
        arView.session.delegate = context.coordinator.frameProcessor
        Logger.shared.log(.info, "ARKitOverlayView: Frame processor (coordinator instance) set as AR session delegate")
        
        // Configure ARKit for real AR experience with iPad compatibility
        let configuration = ARWorldTrackingConfiguration()
        
        // Check if this is an iPad and adjust configuration
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        
        if isIPad {
            // iPad-specific configuration - more conservative settings
            configuration.planeDetection = [.horizontal]  // Only horizontal planes on iPad
            configuration.isAutoFocusEnabled = true
            configuration.worldAlignment = .gravity
            // Don't use environment texturing on iPad to avoid performance issues
            configuration.environmentTexturing = .none
            // Only add depth if strongly supported
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
               ProcessInfo.processInfo.physicalMemory > 4 * 1024 * 1024 * 1024 { // Only on iPads with > 4GB RAM
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            }
        } else {
            // iPhone configuration - full features
            configuration.planeDetection = [.horizontal, .vertical]
            configuration.isAutoFocusEnabled = true
            configuration.worldAlignment = .gravity
            configuration.environmentTexturing = .automatic
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
                configuration.frameSemantics.insert(.smoothedSceneDepth)
            }
        }
        
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        Logger.shared.log(.info, "ARKit: Plane detection ENABLED for surface tracking")
        context.coordinator.isSessionRunning = true
        Logger.shared.log(.info, "ARKit mode: Session started with camera feed")
        
        // Ensure the session is running and verify AR rendering
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let sessionRunning = arView.session.currentFrame != nil
            let sceneAnchorCount = arView.scene.anchors.count
            let isEnabled = arView.isUserInteractionEnabled
            let bounds = arView.bounds
            
            Logger.shared.log(.info, """
                ARKit Rendering Status Check:
                  Session running: \(sessionRunning)
                  Current frame: \(arView.session.currentFrame != nil ? "✅ Available" : "❌ None")
                  Scene anchors: \(sceneAnchorCount)
                  ARView bounds: \(bounds)
                  User interaction: \(isEnabled)
                  Render options: \(arView.renderOptions)
                """)
            
            if !sessionRunning {
                Logger.shared.log(.error, "ARKit mode: No current frame available after setup!")
            } else {
                Logger.shared.log(.info, "ARKit mode: Session running with camera feed")
            }
        }
        
        // Always set up 3D text manager
        textManager.setARView(arView)
        textManager.debugMode = false  // Disable debug for performance
        Logger.shared.log(.info, "ARKit mode: 3D text manager connected with ARView")
        
        // Verify connection was successful
        Logger.shared.log(.info, "ARKit mode: ARView connection verified")
        
        // Create coordinate system anchor at origin
        let originAnchor = AnchorEntity(world: .zero)
        arView.scene.addAnchor(originAnchor)
        
        Logger.shared.log(.info, "ARKit mode: Setup complete with OCR integration")
        
        return arView
    }
    
    func updateUIView(_ arView: ARView, context: Context) {
        // Live mode only controls OCR processing, not camera feed
        let isLiveModeOn = appState.isLiveTranslationEnabled == true
        
        // Update target language in OCR service
        context.coordinator.ocrService.targetLanguage = appState.targetLanguage
        
        // Update frame processor Live mode flag - use coordinator's instance
        let wasEnabled = context.coordinator.frameProcessor.isLiveModeEnabled
        context.coordinator.frameProcessor.isLiveModeEnabled = isLiveModeOn
        
        if wasEnabled != isLiveModeOn {
            Logger.shared.log(.info, "ARKitOverlayView: Live mode changed from \(wasEnabled) to \(isLiveModeOn)")
            
            // Clear AR anchors when Live mode is turned off
            if !isLiveModeOn {
                Logger.shared.log(.info, "ARKitOverlayView: Clearing all AR anchors due to Live mode being disabled")
                textManager.clearAll()
                context.coordinator.textTracker.clear()
            }
            
            // Ensure delegate is still set correctly (in case session was recreated)
            if arView.session.delegate !== context.coordinator.frameProcessor {
                Logger.shared.log(.warning, "ARKitOverlayView: Delegate mismatch detected, updating delegate")
                arView.session.delegate = context.coordinator.frameProcessor
            }
        }
        
        // Ensure session is always running for camera feed
        if !context.coordinator.isSessionRunning {
            // Restart session with plane detection
            let configuration = ARWorldTrackingConfiguration()
            let isIPad = UIDevice.current.userInterfaceIdiom == .pad
            
            if isIPad {
                // iPad-specific configuration
                configuration.planeDetection = [.horizontal]
                configuration.isAutoFocusEnabled = true
                configuration.worldAlignment = .gravity
                configuration.environmentTexturing = .none
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
                   ProcessInfo.processInfo.physicalMemory > 4 * 1024 * 1024 * 1024 {
                    configuration.frameSemantics.insert(.smoothedSceneDepth)
                }
            } else {
                // iPhone configuration
                configuration.planeDetection = [.horizontal, .vertical]
                configuration.isAutoFocusEnabled = true
                configuration.worldAlignment = .gravity
                configuration.environmentTexturing = .automatic
            }
            
            arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
            context.coordinator.isSessionRunning = true
            Logger.shared.log(.info, "ARKit mode: Session restarted for camera feed")
        }
        
        // Clear anchors when Live mode is turned off
        if !isLiveModeOn && textManager.activeAnchors.count > 0 {
            textManager.clearAll()
            textTracker.clear()
            context.coordinator.textTracker.clear()
            Logger.shared.log(.info, "ARKit mode: Cleared anchors (Live mode off)")
        }
        
        // Update distance-based culling only if Live mode is on
        if isLiveModeOn, let frame = arView.session.currentFrame {
            textManager.updateVisibility(cameraTransform: frame.camera.transform)
            let anchorCount = textManager.activeAnchors.count
            if anchorCount > 0 {
                Logger.shared.log(.debug, "ARKitOverlayView update - Active anchors: \(anchorCount)")
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        Logger.shared.log(.info, "ARKit mode: Dismantling ARView - stopping session immediately")
        
        // CRITICAL: Stop session first and clear delegate to stop frame processing
        uiView.session.delegate = nil
        uiView.session.pause()
        
        // Clean up all anchors immediately without delay
        // The session.pause() call is synchronous and will stop frame processing
        uiView.scene.anchors.forEach { $0.removeFromParent() }
        
        // Clear all tracking data
        coordinator.parent.textManager.clearAll()
        coordinator.textTracker.clear()
        coordinator.frameProcessor.cleanup()
        coordinator.frameProcessor.isLiveModeEnabled = false
        coordinator.isSessionRunning = false
        
        // Force release the ARView
        uiView.removeFromSuperview()
        
        Logger.shared.log(.info, "ARKit mode: Session completely stopped and resources released")
    }
    
    // MARK: - Private Methods
    
    private func addSimple3DTextEntity(
        arView: ARView,
        text: String,
        translation: String,
        position: CGRect,
        confidence: Float
    ) {
        Logger.shared.log(.debug, "ARKit mode: Adding 3D text entity for '\(text)' -> '\(translation)'")
        
        // Create text mesh with translation
        let textMesh = MeshResource.generateText(
            translation,
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: 0.02, weight: .medium)
        )
        
        // Create material based on confidence
        var material = SimpleMaterial()
        material.color = .init(tint: confidence > 0.8 ? .systemBlue : .systemGray)
        
        // Create text entity
        let textEntity = ModelEntity(mesh: textMesh, materials: [material])
        
        // Simple 3D positioning based on screen coordinates
        // Place text in front of camera at fixed distance
        let distance: Float = 1.0 // 1 meter in front
        let x = Float((position.midX - 0.5) * 2) * 0.5  // Map to -0.5 to 0.5
        let y = Float((0.5 - position.midY) * 2) * 0.3  // Map to -0.3 to 0.3
        
        let anchorEntity = AnchorEntity(world: SIMD3<Float>(x, y, -distance))
        anchorEntity.name = text
        anchorEntity.addChild(textEntity)
        
        arView.scene.addAnchor(anchorEntity)
        
        Logger.shared.log(.debug, "ARKit mode: Text entity added at position (\(x), \(y), \(-distance))")
    }
    
    // MARK: - Coordinator
    
    @MainActor
    class Coordinator: NSObject {
        let parent: ARKitOverlayView
        var textTracker = TextTracker()  // Made accessible for cleanup
        var arSession: ARSession?
        var isSessionRunning = false
        let frameProcessor: ARFrameProcessor  // Single instance managed by coordinator
        let ocrService = OCRService()  // Made accessible for target language updates
        
        // Method to get current ARFrame for manual capture
        func getCurrentARFrame() -> CVPixelBuffer? {
            return arSession?.currentFrame?.capturedImage
        }
        
        init(_ parent: ARKitOverlayView) {
            self.parent = parent
            self.frameProcessor = ARFrameProcessor(ocrService: ocrService)
            super.init()
            // Set AR mode and target language for enhanced tracking
            textTracker.arMode = .arkit
            ocrService.arMode = .arkit
            ocrService.targetLanguage = parent.appState.targetLanguage
            Logger.shared.log(.info, "ARKitOverlayView Coordinator: Created with persistent frameProcessor instance")
        }
        
        func processDetectedTexts(_ texts: [OCRService.RecognizedText], in arView: ARView) {
            // Update text tracker with new OCR results
            // Note: Live mode is already checked at frame processor level
            textTracker.processNewTexts(texts)
            
            Logger.shared.log(.debug, "ARKit Coordinator: Processing \(texts.count) OCR texts, tracked: \(textTracker.trackedTexts.count)")
            
            // Log what texts are being tracked
            for (index, tracked) in textTracker.trackedTexts.prefix(3).enumerated() {
                Logger.shared.log(.debug, "  [\(index)] '\(tracked.text)' conf:\(tracked.confidence) trans:\(tracked.translation ?? "none")")
            }
            
            // Task to handle async operations
            Task {
                // Immediately update 3D text manager with detected texts (for placeholders)
                await MainActor.run {
                    let trackedTexts = textTracker.trackedTexts
                    Logger.shared.log(.info, """
                        ARKit Coordinator: processDetectedTexts called
                          OCR detected: \(texts.count) texts
                          Currently tracked: \(trackedTexts.count) texts
                          Calling textManager.updateTexts() with \(trackedTexts.count) texts
                        """)
                    parent.textManager.updateTexts(trackedTexts)
                }
                
                // Then translate texts that need translation
                await translateTrackedTexts()
                
                // Update 3D text manager again with translations
                await MainActor.run {
                    let trackedWithTranslations = textTracker.trackedTexts
                    let translatedCount = trackedWithTranslations.filter { $0.translation != nil }.count
                    Logger.shared.log(.info, """
                        ARKit Coordinator: After translation
                          Total tracked: \(trackedWithTranslations.count)
                          With translations: \(translatedCount)
                          Calling textManager.updateTexts() again
                        """)
                    parent.textManager.updateTexts(trackedWithTranslations)
                }
            }
        }
        
        private func translateTrackedTexts() async {
            // Check if we have enabled source languages
            guard let enabledSources = parent.translationCoordinator.appState?.enabledSourceLanguages,
                  !enabledSources.isEmpty else {
                Logger.shared.log(.warning, "ARKit mode: No enabled source languages")
                return
            }
            
            // Collect texts that need translation
            var textsToTranslate: [String] = []
            for tracked in textTracker.trackedTexts {
                if tracked.translation == nil && !tracked.translationFailed {
                    // Check cache first
                    if let cached = TranslationCache.shared.get(for: tracked.text) {
                        var translations = [String: String]()
                        translations[tracked.text] = cached
                        await MainActor.run {
                            textTracker.updateTranslations(translations)
                        }
                    } else {
                        textsToTranslate.append(tracked.text)
                    }
                }
            }
            
            // Translate if needed
            if !textsToTranslate.isEmpty {
                Logger.shared.log(.info, "ARKit mode: Translating \(textsToTranslate.count) texts")
                
                // Mark texts as translating
                await MainActor.run {
                    textTracker.markTextsAsTranslating(textsToTranslate)
                }
                
                // Detect languages and request translations
                let textsByLanguage = parent.translationCoordinator.detectLanguages(for: textsToTranslate)
                
                var allTranslations: [String: String] = [:]
                let group = DispatchGroup()
                
                for (sourceLang, texts) in textsByLanguage {
                    if enabledSources.contains(sourceLang) {
                        group.enter()
                        parent.translationCoordinator.requestTranslation(
                            texts: texts,
                            from: sourceLang,
                            to: parent.appState.targetLanguage
                        ) { translations in
                            for (text, translation) in translations {
                                allTranslations[text] = translation
                            }
                            group.leave()
                        }
                    }
                }
                
                // Wait for all translations
                await withCheckedContinuation { continuation in
                    group.notify(queue: .main) {
                        continuation.resume()
                    }
                }
                
                let translations = allTranslations
                
                await MainActor.run {
                    textTracker.updateTranslations(translations)
                }
            }
        }
    }
    
    private func addTextEntity(
        arView: ARView,
        text: String,
        translation: String,
        position: CGRect,
        confidence: Float
    ) {
        // Create text mesh with translation
        let textMesh = MeshResource.generateText(
            translation,
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: 0.02, weight: .medium)
        )
        
        // Create material based on confidence
        var material = SimpleMaterial()
        if confidence > 0.8 {
            material.color = .init(tint: .systemBlue.withAlphaComponent(0.95))
        } else if confidence > 0.6 {
            material.color = .init(tint: .systemTeal.withAlphaComponent(0.9))
        } else {
            material.color = .init(tint: .systemGray.withAlphaComponent(0.85))
        }
        material.metallic = 0.0
        material.roughness = 0.8
        
        // Create text entity
        let textEntity = ModelEntity(mesh: textMesh, materials: [material])
        textEntity.name = translation
        
        // Create background plane
        let backgroundMesh = MeshResource.generatePlane(
            width: 0.22,
            height: 0.06,
            cornerRadius: 0.008
        )
        var backgroundMaterial = SimpleMaterial()
        backgroundMaterial.color = .init(tint: .white.withAlphaComponent(0.9))
        backgroundMaterial.metallic = 0.0
        backgroundMaterial.roughness = 1.0
        
        let backgroundEntity = ModelEntity(mesh: backgroundMesh, materials: [backgroundMaterial])
        backgroundEntity.position.z = -0.005  // Place behind text
        
        // Create anchor entity at screen position
        let anchorEntity = AnchorEntity()
        anchorEntity.name = text  // Use original text as identifier
        
        // Calculate 3D position from screen coordinates
        let screenPoint = CGPoint(
            x: position.midX * UIScreen.main.bounds.width,
            y: position.midY * UIScreen.main.bounds.height
        )
        
        // Set initial position (in front of camera)
        let distance: Float = 0.5  // 50cm in front
        let x = Float((screenPoint.x / UIScreen.main.bounds.width - 0.5) * 2) * distance
        let y = Float((0.5 - screenPoint.y / UIScreen.main.bounds.height) * 2) * distance
        
        anchorEntity.position = SIMD3<Float>(x, y, -distance)
        
        // Add children to anchor
        anchorEntity.addChild(backgroundEntity)
        anchorEntity.addChild(textEntity)
        
        // Add bounce animation
        let scaleAnimation = FromToByAnimation<Transform>(
            name: "bounce",
            from: Transform(scale: .one * 0.8),
            to: Transform(scale: .one),
            duration: 0.3,
            timing: .easeOut,
            bindTarget: .transform
        )
        
        if let animationResource = try? AnimationResource.generate(with: scaleAnimation) {
            anchorEntity.playAnimation(animationResource)
        }
        
        // Add to scene
        arView.scene.addAnchor(anchorEntity)
    }
    
    private func updateEntityPosition(
        anchorEntity: AnchorEntity,
        position: CGRect,
        arView: ARView
    ) {
        // Calculate new 3D position
        let screenPoint = CGPoint(
            x: position.midX * UIScreen.main.bounds.width,
            y: position.midY * UIScreen.main.bounds.height
        )
        
        let distance: Float = 0.5
        let x = Float((screenPoint.x / UIScreen.main.bounds.width - 0.5) * 2) * distance
        let y = Float((0.5 - screenPoint.y / UIScreen.main.bounds.height) * 2) * distance
        
        // Animate to new position
        var transform = anchorEntity.transform
        transform.translation = SIMD3<Float>(x, y, -distance)
        
        anchorEntity.move(
            to: transform,
            relativeTo: nil,
            duration: 0.2,
            timingFunction: .easeInOut
        )
    }
    
    // MARK: - Debug Helpers
    
    #if DEBUG
    private func addDebugObjects(to arView: ARView) {
        // Add a visible test cube in front of camera
        let boxMesh = MeshResource.generateBox(size: 0.1)
        var material = SimpleMaterial()
        material.color = .init(tint: .systemRed.withAlphaComponent(0.8))
        
        let boxEntity = ModelEntity(mesh: boxMesh, materials: [material])
        
        // Place 0.5m in front at origin
        let anchor = AnchorEntity(world: SIMD3<Float>(0, 0, -0.5))
        anchor.name = "debug_cube"
        anchor.addChild(boxEntity)
        
        arView.scene.addAnchor(anchor)
        
        // Add test text
        let textMesh = MeshResource.generateText(
            "AR Debug Active",
            extrusionDepth: 0.01,
            font: .systemFont(ofSize: 0.05)
        )
        var textMaterial = SimpleMaterial()
        textMaterial.color = .init(tint: .systemGreen)
        
        let textEntity = ModelEntity(mesh: textMesh, materials: [textMaterial])
        let textAnchor = AnchorEntity(world: SIMD3<Float>(0, 0.2, -0.5))
        textAnchor.name = "debug_text"
        textAnchor.addChild(textEntity)
        
        arView.scene.addAnchor(textAnchor)
        
        Logger.shared.log(.info, "ARKit: Debug objects added (red cube and green text at 0.5m)")
    }
    
    private func updateDebugOverlay(arView: ARView, anchorCount: Int) {
        // Find or create debug status text
        if let debugAnchor = arView.scene.findEntity(named: "debug_status") as? AnchorEntity {
            // Update existing text
            if let textEntity = debugAnchor.children.first as? ModelEntity {
                // Recreate text mesh with updated info
                let statusText = "Anchors: \(anchorCount)\nFPS: \(Int(1.0 / (arView.session.currentFrame?.timestamp ?? 1.0)))"
                let newMesh = MeshResource.generateText(
                    statusText,
                    extrusionDepth: 0.001,
                    font: .systemFont(ofSize: 0.03)
                )
                textEntity.model?.mesh = newMesh
            }
        } else {
            // Create debug status display
            let statusText = "Anchors: \(anchorCount)"
            let textMesh = MeshResource.generateText(
                statusText,
                extrusionDepth: 0.001,
                font: .systemFont(ofSize: 0.03)
            )
            
            var material = SimpleMaterial()
            material.color = .init(tint: .systemYellow)
            
            let textEntity = ModelEntity(mesh: textMesh, materials: [material])
            let statusAnchor = AnchorEntity(world: SIMD3<Float>(-0.3, 0.3, -0.5))
            statusAnchor.name = "debug_status"
            statusAnchor.addChild(textEntity)
            
            arView.scene.addAnchor(statusAnchor)
        }
    }
    #endif
}

// MARK: - Preview

@available(iOS 18.0, *)
struct ARKitOverlayView_Previews: PreviewProvider {
    @State static var coordinator: ARKitOverlayView.Coordinator? = nil
    
    static var previews: some View {
        ARKitOverlayView(
            translationCoordinator: TranslationCoordinator(),
            arkitCoordinator: .constant(nil)
        )
        .environmentObject(AppState())
    }
}