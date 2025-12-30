//
//  CameraView.swift
//  ViewLingo-Cam
//
//  Main camera view with AR translation overlay
//

import SwiftUI
import AVFoundation
import Translation
import Metal

@available(iOS 18.0, *)
struct CameraView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var ocrService = OCRService()
    @StateObject private var translationCoordinator = TranslationCoordinator()
    @StateObject private var languageService = LanguagePackService.shared
    @StateObject private var textTracker = TextTracker()
    @StateObject private var sceneDetector = SceneChangeDetector()
    
    @State private var showSettings = false
    @State private var isInSettings = false  // Track if settings is open
    @State private var previousARMode: ARMode? = nil  // Track previous mode for change detection
    @State private var useHybridTracking = false  // Temporarily disabled until fully debugged
    @State private var isLiveMode = false
    @State private var processTimer: Timer?
    @State private var showLanguageSelector = false
    @State private var frameCounter = 0
    @State private var isCurrentlyProcessing = false
    @State private var isProcessingPaused = false  // Pause processing during manual capture
    @State private var lastFullOCRFrame = 0  // Track when we last did full OCR
    @State private var recentJapaneseDetection = false
    @State private var lastJapaneseDetectionTime: Date?
    @State private var consecutiveJapaneseFrames = 0  // Track consecutive frames with Japanese
    @State private var textsBeingTranslated = Set<String>()  // Track texts currently being translated
    @State private var sessionProviderKey = UUID()  // Force re-render of BatchLanguagePackProvider
    @State private var sessionsInitialized = false  // Track if sessions are initialized
    @State private var isCameraReady = false  // Track camera initialization
    @State private var cameraPermissionDenied = false  // Track permission denial
    @State private var hasAttemptedLanguagePackInstall = false  // Track if we've tried to trigger iOS UI
    
    // Capture photo states
    @State private var capturedImage: UIImage?
    @State private var showCapturedView = false
    @State private var capturedTexts: [TrackedText] = []
    
    // ARKit coordinator reference for manual capture
    @State private var arkitCoordinator: ARKitOverlayView.Coordinator?
    
    // OCR Mode tracking
    enum OCRMode {
        case initial      // First capture or manual capture - accurate mode
        case tracking     // Live mode tracking - use masking and fast mode
        case refresh      // Periodic refresh - accurate mode without masking
    }
    @State private var currentOCRMode: OCRMode = .initial
    
    @ViewBuilder
    private var cameraContent: some View {
        if !isInSettings {
            if appState.arMode == .arkit {
                // ARKit mode: ARView handles both camera and rendering
                ARKitOverlayView(
                    translationCoordinator: translationCoordinator,
                    arkitCoordinator: $arkitCoordinator
                )
                .ignoresSafeArea()
                .environmentObject(appState)
            } else {
                // Standard mode: Traditional camera + overlay structure
                ZStack {
                    CameraPreviewView(cameraManager: cameraManager)
                        .ignoresSafeArea()
                    
                    // Box style overlay
                    BoxTranslationOverlay(
                        trackedTexts: textTracker.trackedTexts
                    )
                    .ignoresSafeArea()
                    .id(textTracker.trackedTexts.count) // Force refresh when count changes
                }
            }
        }
    }
    
    @ViewBuilder
    private var translationSessionsContent: some View {
        // Translation executor that handles requests without storing sessions
        TranslationExecutor(coordinator: translationCoordinator)
            .frame(width: 0, height: 0)
            .opacity(0)
        
        // Language pack installer for initial setup
        BatchLanguagePackProvider(
            targetLanguage: appState.targetLanguage,
            onSessionReady: { session, source, target in
                // Mark language pair as installed when session is ready
                if session != nil {
                    translationCoordinator.markLanguagePairInstalled(source: source, target: target)
                    Logger.shared.log(.info, "✅ Language pair installed: \(source)→\(target)")
                }
            },
            onBatchComplete: { completedPairs in
                Logger.shared.log(.info, "📦 Batch installation complete: \(completedPairs.count) pairs")
                sessionsInitialized = true
            }
        )
        .environmentObject(appState)
        .id(sessionProviderKey)
    }
    
    var body: some View {
        ZStack {
            // Camera views - only render when not in settings
            cameraContent
        }
        // Translation sessions placed outside ZStack for stable lifecycle
        .background(
            translationSessionsContent
                .opacity(0)
                .allowsHitTesting(false)
        )
        .onAppear {
            // Connect appState to translationCoordinator
            translationCoordinator.appState = appState
        }
        .safeAreaInset(edge: .top) {
            // Top controls bar
            HStack {
                // Settings button
                Button(action: { showSettings.toggle() }) {
                    Image(systemName: "gearshape.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding(12)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .disabled(!isCameraReady || !sessionsInitialized)
                .opacity((isCameraReady && sessionsInitialized) ? 1.0 : 0.5)
                
                Spacer()
                
                // Target language selector
                Button(action: { showLanguageSelector.toggle() }) {
                    HStack(spacing: 8) {
                        Text(languageService.getLanguageEmoji(appState.targetLanguage))
                        Text(languageService.getLanguageName(appState.targetLanguage))
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .foregroundColor(.white)
                }
                .disabled(!isCameraReady || !sessionsInitialized)
                .opacity((isCameraReady && sessionsInitialized) ? 1.0 : 0.5)
                
                Spacer()
                
                // Live mode toggle
                Button(action: toggleLiveMode) {
                    Image(systemName: isLiveMode ? "livephoto" : "livephoto.slash")
                        .font(.title2)
                        .foregroundColor(isLiveMode ? .green : .white)
                        .padding(12)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .disabled(!isCameraReady || !sessionsInitialized)
                .opacity((isCameraReady && sessionsInitialized) ? 1.0 : 0.5)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.3))
        }
        .safeAreaInset(edge: .bottom) {
            // Bottom capture button - Only show in Standard mode
            // ARKit mode is live-only and doesn't support manual capture
            if appState.arMode != .arkit {
                Button(action: isLiveMode ? capturePhoto : captureAndProcess) {
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                    
                        .frame(width: 70, height: 70)
                        .overlay(
                            Circle()
                                .fill(Color.white)
                                .frame(width: 60, height: 60)
                        )
                }
                .disabled(!isCameraReady || !sessionsInitialized)  // Disable until ready
                .opacity((isCameraReady && sessionsInitialized) ? 1.0 : 0.5)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.3))
            } else {
                // ARKit mode disabled for initial release
                // Text(LocalizationService.L("arkit_live_only", appState.targetLanguage))
                //     .font(.caption)
                //     .foregroundColor(.white.opacity(0.7))
                //     .padding(.vertical, 12)
                //     .frame(maxWidth: .infinity)
                //     .background(Color.black.opacity(0.3))
                // Since ARKit is hidden, this else block should not be reached
                EmptyView()
            }
        }
        .overlay(
            // Loading indicator or permission denied UI
            Group {
                if cameraPermissionDenied {
                    // Camera permission denied UI
                    VStack(spacing: 16) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.white.opacity(0.8))
                        
                        Text(LocalizationService.L("camera_permission_denied"))
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                        
                        Text(LocalizationService.L("camera_permission_denied_desc"))
                            .font(.body)
                            .foregroundColor(.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        Button(action: openSettings) {
                            HStack {
                                Image(systemName: "gearshape.fill")
                                Text(LocalizationService.L("open_settings"))
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(25)
                        }
                        .padding(.top, 8)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.9))
                } else if !isCameraReady || !sessionsInitialized {
                    // Loading indicator
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.5)
                        
                        Text(LocalizationService.L("camera_preparing"))
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                    .padding(24)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(12)
                }
            }
        )
        .onAppear {
            setupCamera()
        }
        .onDisappear {
            cleanup()
        }
        .onChange(of: cameraManager.frameUpdateCount) { _, _ in
            // Only process frames if NOT in ARKit mode
            // ARKit mode should handle its own frame processing through ARSession
            if appState.arMode != .arkit && isLiveMode, let buffer = cameraManager.currentFrame {
                frameCounter += 1
                
                // Determine OCR mode and processing frequency based on AR mode
                let shouldProcess: Bool
                let framesSinceFullOCR = frameCounter - lastFullOCRFrame
                
                // Check if we recently detected Japanese text
                let hasRecentJapanese = recentJapaneseDetection && 
                                      lastJapaneseDetectionTime != nil && 
                                      Date().timeIntervalSince(lastJapaneseDetectionTime!) < 2.0
                
                // Optimized for 15fps camera - process most frames
                if appState.arMode == .standard {
                    // Standard mode: Process all frames at 15fps
                    if framesSinceFullOCR >= 15 {  // Refresh every 1 second at 15fps
                        currentOCRMode = .refresh
                        shouldProcess = true
                    } else {
                        // Always track at 15fps - camera is already optimized
                        currentOCRMode = .tracking
                        shouldProcess = true
                        
                        // Log Japanese detection less frequently
                        if hasRecentJapanese && frameCounter % 15 == 0 {
                            Logger.shared.log(.debug, "Japanese text tracking active")
                        }
                    }
                } else {
                    // Legacy mode: Same as standard for consistency
                    if framesSinceFullOCR >= 15 {  // Refresh every 1 second at 15fps
                        currentOCRMode = .refresh
                        shouldProcess = true
                    } else {
                        currentOCRMode = .tracking
                        shouldProcess = true
                    }
                }
                
                if shouldProcess && !isCurrentlyProcessing && !isProcessingPaused {
                    Task {
                        await processFrame(buffer)
                    }
                    
                    // Safety timeout with comprehensive recovery
                    Task {
                        try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                        await MainActor.run {
                            if isCurrentlyProcessing {
                                Logger.shared.log(.warning, "⚠️ Force resetting after 5s timeout - performing full recovery")
                                
                                // Reset processing flag
                                isCurrentlyProcessing = false
                                
                                // Clear all pending translations
                                textsBeingTranslated.removeAll()
                                
                                // Clear text tracker to restart fresh
                                textTracker.clear()
                                
                                // Clear OCR service
                                ocrService.clear()
                                
                                // Clear translation cache to avoid stale data
                                TranslationCache.shared.clear()
                                
                                // Reset OCR mode to initial for fresh start
                                currentOCRMode = .initial
                                lastFullOCRFrame = 0
                                frameCounter = 0
                                
                                // Reset Japanese detection state
                                recentJapaneseDetection = false
                                consecutiveJapaneseFrames = 0
                                lastJapaneseDetectionTime = nil
                                
                                Logger.shared.log(.info, "✅ Full recovery completed - ready for fresh start")
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: appState.targetLanguage) { _, newTarget in
            // Clear everything when target language changes
            // Sessions are no longer stored, regenerate provider key instead
            sessionProviderKey = UUID()
            textTracker.clear()
            TranslationCache.shared.clear()
            textsBeingTranslated.removeAll()
            Logger.shared.log(.info, "Target language changed to: \(newTarget)")
            
            // Force BatchLanguagePackProvider to re-render and create new sessions
            sessionProviderKey = UUID()
            Logger.shared.log(.info, "🔄 Forcing BatchLanguagePackProvider re-render for new target language")
            
            // Wait a bit then check if sessions were created
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds
                await MainActor.run {
                    // Check if language packs are installed
                    Logger.shared.log(.info, "✅ Language pack re-initialization triggered")
                }
            }
        }
        .onChange(of: appState.arMode) { oldMode, newMode in
            // Mode changes only happen in settings, where camera is already stopped
            // So we just need to clear texts and prepare for the new mode
            Logger.shared.log(.info, "AR mode changed from \(oldMode.rawValue) to \(newMode.rawValue) (will apply when settings close)")
            
            // Clear text tracker for the new mode
            textTracker.clearAllTexts()
            ocrService.clear()
            sceneDetector.reset()
            
            // Clear tracking data
            // Note: HybridTracker temporarily disabled
            
            Logger.shared.log(.info, "Cleared tracking data for mode switch")
        }
        .fullScreenCover(isPresented: $showSettings) {
            SettingsView()
                .onAppear {
                    Logger.shared.log(.info, "Settings opened - turning off Live mode and clearing texts")
                    
                    // Mark as in settings and save current mode
                    isInSettings = true
                    previousARMode = appState.arMode
                    
                    // Turn off Live mode if it was on
                    if isLiveMode {
                        isLiveMode = false
                        appState.isLiveTranslationEnabled = false
                        processTimer?.invalidate()
                        processTimer = nil
                        Logger.shared.log(.info, "Live mode turned OFF for settings")
                    }
                    
                    // Pause camera to prevent frame drops (only for Standard mode)
                    if appState.arMode == .standard {
                        cameraManager.pauseSession()
                        Logger.shared.log(.info, "Camera paused for settings")
                    }
                    
                    // Clear all recognized texts and translations
                    textTracker.clearAllTexts()
                    ocrService.clear()
                    TranslationCache.shared.clear()
                    textsBeingTranslated.removeAll()
                    sceneDetector.reset()
                    
                    // Clear Japanese detection state
                    recentJapaneseDetection = false
                    lastJapaneseDetectionTime = nil
                    consecutiveJapaneseFrames = 0
                    
                    Logger.shared.log(.info, "All texts and recognition cleared for settings")
                }
                .onDisappear {
                    // When settings close, restart camera with clean state
                    let modeChanged = previousARMode != nil && previousARMode != appState.arMode
                    Logger.shared.log(.info, "Settings closed - mode: \(appState.arMode.rawValue), changed: \(modeChanged)")
                    
                    // Mark as not in settings anymore
                    isInSettings = false
                    
                    // Add delay to ensure mode change has been applied and old views cleaned up
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)  // 300ms delay
                        
                        await MainActor.run {
                            // Reset frame counters
                            frameCounter = 0
                            lastFullOCRFrame = 0
                            currentOCRMode = .initial
                            
                            // Clear tracking again to ensure clean start
                            textTracker.clear()
                            ocrService.clear()
                            
                            // Reset processing flags
                            isCurrentlyProcessing = false
                            textsBeingTranslated.removeAll()
                            
                            // Handle mode change or restart
                            if modeChanged {
                                Logger.shared.log(.info, "Mode changed from \(previousARMode?.rawValue ?? "nil") to \(appState.arMode.rawValue)")
                                
                                if appState.arMode == .standard {
                                    // Switching to Standard mode - need full camera setup
                                    Logger.shared.log(.info, "Initializing camera for Standard mode")
                                    isCameraReady = false  // Reset camera ready state
                                    
                                    // Configure and start camera session
                                    Task {
                                        await cameraManager.configureCaptureSession()
                                        cameraManager.startSession()
                                        await MainActor.run {
                                            isCameraReady = true
                                            Logger.shared.log(.info, "Camera ready for Standard mode")
                                        }
                                    }
                                } else if appState.arMode == .arkit {
                                    // Switching to ARKit mode
                                    Logger.shared.log(.info, "ARKit mode will initialize its own camera")
                                    isCameraReady = true  // ARKit manages its own camera
                                }
                            } else {
                                // No mode change, just resume
                                if appState.arMode == .standard {
                                    cameraManager.resumeSession()
                                    Logger.shared.log(.info, "CameraManager resumed for Standard mode")
                                } else {
                                    Logger.shared.log(.info, "ARKit mode camera continues")
                                }
                            }
                        }
                    }
                }
        }
        .sheet(isPresented: $showLanguageSelector) {
            LanguageSelectorView(
                selectedLanguage: $appState.targetLanguage,
                currentTargetLanguage: appState.targetLanguage
            )
        }
        .fullScreenCover(isPresented: $showCapturedView) {
            if let image = capturedImage {
                CapturedImageView(
                    image: image,
                    trackedTexts: $capturedTexts,
                    isPresented: $showCapturedView,
                    appState: appState,
                    translationCoordinator: translationCoordinator
                )
            }
        }
        .onChange(of: showCapturedView) { _, isShowing in
            if isShowing {
                // Pause live processing when manual capture is active
                cameraManager.pauseSession()
                isProcessingPaused = true
                Logger.shared.log(.info, "📸 Manual capture active - pausing live processing")
            } else {
                // Resume live processing when manual capture is closed
                // Reset processing state to ensure clean resume
                isCurrentlyProcessing = false
                textsBeingTranslated.removeAll()
                isProcessingPaused = false
                
                // Resume camera
                cameraManager.startSession()
                Logger.shared.log(.info, "▶️ Manual capture closed - resuming live processing (processing flags reset)")
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func openSettings() {
        if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(settingsURL)
        }
    }
    
    // MARK: - Setup & Cleanup
    
    private func setupCamera() {
        Logger.shared.log(.info, "Setting up camera view - AR mode: \(appState.arMode.rawValue)")
        
        // Check language pack status (but don't trigger downloads!)
        Task {
            await languageService.checkStatusForTarget(appState.targetLanguage)
            
            // Wait briefly for BatchLanguagePackProvider to initialize
            try? await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second
            
            await MainActor.run {
                let hasInstalledPacks = !translationCoordinator.installedLanguagePairs.isEmpty
                let hasMinimumSessions = languageService.hasMinimumSessionsForTarget(appState.targetLanguage)
                
                // If no sessions and we haven't tried installing yet, force BatchLanguagePackProvider recreation
                if !hasInstalledPacks && !hasAttemptedLanguagePackInstall {
                    Logger.shared.log(.warning, "⚠️ No sessions available, forcing BatchLanguagePackProvider recreation")
                    hasAttemptedLanguagePackInstall = true
                    
                    // Force BatchLanguagePackProvider to recreate and trigger iOS UI
                    sessionProviderKey = UUID()
                    Logger.shared.log(.info, "🔄 Triggering BatchLanguagePackProvider to install language packs")
                } else if !hasInstalledPacks {
                    Logger.shared.log(.warning, "⚠️ No language packs installed by BatchLanguagePackProvider")
                    createFallbackSessions()
                } else if !hasMinimumSessions {
                    // Not enough validated sessions
                    let missingPairs = languageService.getMissingPairs(for: appState.targetLanguage)
                    Logger.shared.log(.warning, """
                        ⚠️ Insufficient validated sessions for \(appState.targetLanguage)
                          - Installed pairs: \(translationCoordinator.installedLanguagePairs.count)
                          - Missing pairs: \(missingPairs.map { $0.key }.joined(separator: ", "))
                        """)
                    // Force recreation to trigger iOS UI for missing packs
                    sessionProviderKey = UUID()
                    Logger.shared.log(.info, "🔄 Triggering BatchLanguagePackProvider for missing language packs")
                } else {
                    Logger.shared.log(.info, "✅ Language packs validated and ready")
                }
            }
        }
        
        // Only start camera manager if NOT in ARKit mode
        // ARKit mode uses its own camera through ARSession
        if appState.arMode != .arkit {
            Logger.shared.log(.info, "Starting CameraManager for \(appState.arMode.rawValue) mode")
            
            Task {
                // CRITICAL: Request camera permission FIRST and wait for result
                let hasPermission = await cameraManager.checkAndRequestAuthorization()
                
                if hasPermission {
                    Logger.shared.log(.info, "✅ Camera permission granted, initializing camera...")
                    
                    // Add a small delay to ensure UI is ready
                    try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms
                    
                    await cameraManager.configureCaptureSession()
                    cameraManager.startSession()
                    
                    await MainActor.run {
                        isCameraReady = true
                    }
                } else {
                    Logger.shared.log(.error, "❌ Camera permission denied, cannot start camera")
                    
                    await MainActor.run {
                        isCameraReady = false
                        cameraPermissionDenied = true
                    }
                }
            }
        } else {
            Logger.shared.log(.info, "Skipping CameraManager - ARKit mode will use ARSession camera")
            // ARKit mode uses its own camera through ARSession, mark as ready immediately
            isCameraReady = true
        }
        
        // Note: HybridTracker temporarily disabled
    }
    
    private func createFallbackSessions() {
        Logger.shared.log(.error, "❌ No sessions created by BatchLanguagePackProvider")
        Logger.shared.log(.info, "📊 Translation coordinator ready")
        
        // Force BatchLanguagePackProvider recreation to trigger iOS system UI
        sessionProviderKey = UUID()
        
        Logger.shared.log(.info, "🔄 Triggering BatchLanguagePackProvider recreation for language pack installation")
    }
    
    private func cleanup() {
        Logger.shared.log(.info, "Cleaning up camera view")
        
        processTimer?.invalidate()
        processTimer = nil
        cameraManager.stopSession()
        ocrService.clear()
        textTracker.clear()
        TranslationCache.shared.clear()
        
        // Note: HybridTracker temporarily disabled
    }
    
    // MARK: - Processing
    
    private func toggleLiveMode() {
        isLiveMode.toggle()
        
        // Update AppState for ARKit mode to know about Live mode
        appState.isLiveTranslationEnabled = isLiveMode
        
        if isLiveMode {
            Logger.shared.log(.info, "Live mode enabled")
            frameCounter = 0
            lastFullOCRFrame = 0
            currentOCRMode = .initial  // Start with full OCR
        } else {
            Logger.shared.log(.info, "Live mode disabled")
            
            // Clear all texts and anchors regardless of AR mode
            textTracker.clearAllTexts()
            ocrService.clear()
            
            // For ARKit mode, also trigger anchor cleanup
            // This will be handled by ARKitOverlayView through appState change
            if appState.arMode == .arkit {
                Logger.shared.log(.info, "Live mode disabled in ARKit - anchors will be cleared")
            }
            
            // Use accurate mode for manual capture
            ocrService.setRecognitionMode(.accurate)
            currentOCRMode = .initial
            processTimer?.invalidate()
            processTimer = nil
        }
    }
    
    private func captureAndProcess() {
        // For manual capture, take a still image and process it
        // Works the same for both ARKit and Standard modes
        
        var buffer: CVPixelBuffer?
        
        // For portrait mode, use up orientation so image displays correctly
        let orientation: UIImage.Orientation = .up
        
        if appState.arMode == .arkit {
            // For ARKit mode, get current frame from ARSession
            if let currentFrame = arkitCoordinator?.getCurrentARFrame() {
                buffer = currentFrame
                Logger.shared.log(.info, "ARKit mode: Using current ARSession frame for manual capture")
            } else {
                Logger.shared.log(.warning, "ARKit mode: No current frame from ARSession, falling back to camera manager")
                buffer = cameraManager.currentFrame
            }
        } else {
            // Standard mode - get from camera manager
            buffer = cameraManager.currentFrame
        }
        
        guard let pixelBuffer = buffer else {
            Logger.shared.log(.warning, "No current frame available for capture")
            return
        }
        
        // Convert CVPixelBuffer to UIImage
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Use shared CIContext for iPad compatibility and better performance
        let context = CIContextHelper.shared
        
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            capturedImage = UIImage(cgImage: cgImage, scale: 1.0, orientation: orientation)
            
            // Clear and prepare for new capture
            capturedTexts = []
            
            // Show captured view - it will perform its own high-quality OCR
            showCapturedView = true
            
            Logger.shared.log(.info, "Manual capture initiated (mode: \(appState.arMode.rawValue), orientation: \(orientation.rawValue))")
        } else {
            Logger.shared.log(.error, "Failed to create image from buffer")
        }
    }
    
    private func capturePhoto() {
        guard let buffer = cameraManager.currentFrame else { return }
        
        // Convert CVPixelBuffer to UIImage
        let ciImage = CIImage(cvPixelBuffer: buffer)
        
        // Use shared CIContext for iPad compatibility and better performance
        let context = CIContextHelper.shared
        
        if let cgImage = context.createCGImage(ciImage, from: ciImage.extent) {
            capturedImage = UIImage(cgImage: cgImage)
            
            // Capture current tracked texts
            capturedTexts = textTracker.trackedTexts
            
            // Perform accurate OCR on the captured image
            Task {
                ocrService.setRecognitionMode(.accurate)
                await ocrService.processImage(ciImage)
                
                // Update captured texts with new OCR results
                await MainActor.run {
                    let newTracker = TextTracker()
                    newTracker.processNewTexts(ocrService.recognizedTexts)
                    
                    // Translate using coordinator
                    let textsToTranslate = newTracker.trackedTexts.map { $0.text }
                    if !textsToTranslate.isEmpty {
                        Task {
                            // Detect languages for texts
                            let textsByLanguage = translationCoordinator.detectLanguages(for: textsToTranslate)
                            
                            // Request translation for each detected language
                            for (sourceLang, texts) in textsByLanguage {
                                if let enabledSources = translationCoordinator.appState?.enabledSourceLanguages,
                                   enabledSources.contains(sourceLang) {
                                    translationCoordinator.requestTranslation(
                                        texts: texts,
                                        from: sourceLang,
                                        to: appState.targetLanguage
                                    ) { translations in
                                        Task { @MainActor in
                                            newTracker.updateTranslations(translations)
                                            capturedTexts = newTracker.trackedTexts
                                            showCapturedView = true
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        capturedTexts = newTracker.trackedTexts
                        showCapturedView = true
                    }
                }
            }
        }
    }
    
    private func processFrame(_ buffer: CVPixelBuffer) async {
        // Prevent concurrent processing
        guard !isCurrentlyProcessing else { 
            Logger.shared.log(.debug, "Skipping frame - already processing")
            return 
        }
        isCurrentlyProcessing = true
        
        // Ensure flag is reset no matter what happens
        defer {
            Task { @MainActor in
                isCurrentlyProcessing = false
            }
        }
        
        // Set AR mode and target language in OCR service for adaptive filtering
        ocrService.arMode = appState.arMode
        ocrService.targetLanguage = appState.targetLanguage
        
        // Configure OCR based on current mode
        let excludeRegions: [CGRect]
        switch currentOCRMode {
        case .initial:
            // Full accurate OCR, no masking
            ocrService.setRecognitionMode(.accurate)
            excludeRegions = []
            Logger.shared.log(.debug, "OCR Mode: Initial (accurate, no masking)")
            
        case .tracking:
            // When Japanese text was recently detected, use Accurate mode for consistency
            // Japanese text has issues with Fast mode (gets filtered as "too small")
            if recentJapaneseDetection {
                ocrService.setRecognitionMode(.accurate)
                excludeRegions = []  // No masking for Japanese
                Logger.shared.log(.debug, "OCR Mode: Tracking (accurate for Japanese, no masking)")
            } else {
                // Fast OCR for other languages
                ocrService.setRecognitionMode(.fast)
                // Standard mode: Don't mask regions to allow quality improvements
                excludeRegions = appState.arMode == .standard ? [] : textTracker.getTrackedRegions()
                let maskingStatus = appState.arMode == .standard ? "no masking" : "\(excludeRegions.count) masked regions"
                Logger.shared.log(.debug, "OCR Mode: Tracking (fast, \(maskingStatus))")
            }
            
        case .refresh:
            // Periodic full accurate OCR to verify tracking
            ocrService.setRecognitionMode(.accurate)
            excludeRegions = []
            lastFullOCRFrame = frameCounter
            Logger.shared.log(.debug, "OCR Mode: Refresh (accurate, no masking)")
        }
        
        // Perform OCR with appropriate masking
        await ocrService.processBuffer(buffer, excludeRegions: excludeRegions)
        
        // Update text tracker with new OCR results and pass AR mode
        await MainActor.run {
            // Check if Japanese text was detected
            let hasJapanese = ocrService.recognizedTexts.contains { text in
                text.text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", 
                               options: .regularExpression) != nil
            }
            
            if hasJapanese {
                recentJapaneseDetection = true
                lastJapaneseDetectionTime = Date()
                consecutiveJapaneseFrames += 1
                Logger.shared.log(.debug, "Japanese text detected in \(ocrService.recognizedTexts.count) texts (consecutive: \(consecutiveJapaneseFrames))")
            } else if recentJapaneseDetection {
                // Keep Japanese mode active for a few frames even if not detected
                if consecutiveJapaneseFrames > 0 {
                    consecutiveJapaneseFrames -= 1
                    if consecutiveJapaneseFrames == 0 {
                        recentJapaneseDetection = false
                        Logger.shared.log(.debug, "Exiting Japanese detection mode")
                    }
                }
            }
            
            // Analyze scene changes
            let sceneState = sceneDetector.analyzeFrame(
                texts: ocrService.recognizedTexts,
                trackedTexts: textTracker.trackedTexts
            )
            
            // Handle scene transitions
            if sceneState == .transitioning {
                Logger.shared.log(.info, "Scene transition detected - clearing overlays")
                textTracker.clear()
                ocrService.clear()
                TranslationCache.shared.clear()
                textsBeingTranslated.removeAll()
                // Force refresh mode on next frame
                currentOCRMode = .initial
                lastFullOCRFrame = 0
            }
            
            // Apply persistence multiplier based on scene state
            let persistenceMultiplier = sceneDetector.getPersistenceMultiplier()
            textTracker.scenePersistenceMultiplier = persistenceMultiplier
            
            // Set AR mode in text tracker for enhanced tracking
            textTracker.arMode = appState.arMode
            textTracker.processNewTexts(ocrService.recognizedTexts)
            
            // Note: HybridTracker temporarily disabled
            
            // After initial or refresh, switch to tracking mode
            if currentOCRMode == .initial || currentOCRMode == .refresh {
                currentOCRMode = .tracking
            }
        }
        
        // Note: HybridTracker temporarily disabled
        
        // Check if we have enabled source languages
        guard let enabledSources = translationCoordinator.appState?.enabledSourceLanguages,
              !enabledSources.isEmpty else {
            Logger.shared.log(.warning, "No enabled source languages, skipping")
            return
        }
        
        // Only translate texts that don't have translations yet
        var textsToTranslate: [String] = []
        var textsToMarkFailed: [String] = []
        
        for tracked in textTracker.trackedTexts {
            // Skip if already has translation or failed
            if tracked.translation != nil || tracked.translationFailed {
                continue
            }
            
            // Skip if confidence too low
            if tracked.confidence <= 0.3 {
                continue
            }
            
            // Skip if currently being translated
            if textsBeingTranslated.contains(tracked.text) {
                continue
            }
            
            // Skip if too many attempts
            if tracked.translationAttempts >= 3 {
                textsToMarkFailed.append(tracked.text)
                continue
            }
            
            // Check cache first
            if let cachedTranslation = TranslationCache.shared.get(for: tracked.text) {
                // Apply cached translation directly
                var translations = [String: String]()
                translations[tracked.text] = cachedTranslation
                await MainActor.run {
                    textTracker.updateTranslations(translations)
                }
                continue
            }
            
            textsToTranslate.append(tracked.text)
        }
        
        // Mark failed texts
        if !textsToMarkFailed.isEmpty {
            await MainActor.run {
                textTracker.markTranslationFailed(for: textsToMarkFailed)
            }
        }
        
        guard !textsToTranslate.isEmpty else {
            Logger.shared.log(.debug, "No new texts need translation")
            return
        }
        
        Logger.shared.log(.info, "Translating \(textsToTranslate.count) new texts")
        
        // Mark texts as being translated
        await MainActor.run {
            textsToTranslate.forEach { textsBeingTranslated.insert($0) }
        }
        
        // Limit number of texts to translate to avoid overload
        let maxTextsToTranslate = min(textsToTranslate.count, 5)
        let limitedTextsToTranslate = Array(textsToTranslate.prefix(maxTextsToTranslate))
        
        if textsToTranslate.count > maxTextsToTranslate {
            Logger.shared.log(.info, "Limiting translation to \(maxTextsToTranslate) texts out of \(textsToTranslate.count)")
        }
        
        // Detect languages and request translations
        let textsByLanguage = translationCoordinator.detectLanguages(for: limitedTextsToTranslate)
        
        var allTranslations: [String: String] = [:]
        
        // Create async translation tasks with timeout
        let targetLang = appState.targetLanguage  // Capture before task group
        
        await withTaskGroup(of: [String: String].self) { group in
            for (sourceLang, texts) in textsByLanguage {
                // Skip same-language translations
                if sourceLang == targetLang {
                    Logger.shared.log(.warning, "Skipping same-language translation: \(sourceLang)→\(sourceLang)")
                    continue
                }
                
                if enabledSources.contains(sourceLang) {
                    group.addTask { @MainActor in
                        // Wrap the callback-based API in async/await with timeout
                        let translations = await withTaskCancellationHandler {
                            await withCheckedContinuation { continuation in
                                // Thread-safe flag to prevent double resume
                                var isResumed = false
                                let lock = NSLock()
                                
                                // Set up a timer for timeout
                                let timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
                                    lock.lock()
                                    defer { lock.unlock() }
                                    guard !isResumed else { 
                                        Logger.shared.log(.debug, "Timer fired but continuation already resumed for \(sourceLang)")
                                        return 
                                    }
                                    isResumed = true
                                    Logger.shared.log(.warning, "Translation timeout for \(sourceLang)")
                                    continuation.resume(returning: [String: String]())
                                }
                                
                                self.translationCoordinator.requestTranslation(
                                    texts: texts,
                                    from: sourceLang,
                                    to: targetLang
                                ) { translationResults in
                                    lock.lock()
                                    defer { lock.unlock() }
                                    timer.invalidate()
                                    guard !isResumed else { 
                                        Logger.shared.log(.debug, "Translation completed but continuation already resumed for \(sourceLang)")
                                        return 
                                    }
                                    isResumed = true
                                    Logger.shared.log(.info, "📝 Received \(translationResults.count) translations for \(sourceLang)→\(targetLang)")
                                    continuation.resume(returning: translationResults)
                                }
                            }
                        } onCancel: {
                            Logger.shared.log(.debug, "Translation task cancelled for \(sourceLang)")
                        }
                        
                        return translations
                    }
                }
            }
            
            // Collect all translation results
            for await translations in group {
                for (text, translation) in translations {
                    allTranslations[text] = translation
                    Logger.shared.log(.debug, "Translation: '\(String(text.prefix(20)))...' → '\(String(translation.prefix(20)))...'")
                }
            }
        }
        
        // Clear stuck translations if needed
        if allTranslations.isEmpty && !limitedTextsToTranslate.isEmpty {
            Logger.shared.log(.warning, "No translations received - clearing stuck texts")
            await MainActor.run {
                textsBeingTranslated.removeAll()
            }
        }
        
        let translations = allTranslations
        
        // Mark any texts that failed to translate
        let failedTexts = textsToTranslate.filter { translations[$0] == nil || translations[$0]?.isEmpty == true }
        if !failedTexts.isEmpty {
            await MainActor.run {
                textTracker.markTranslationFailed(for: failedTexts)
            }
        }
        
        // Update tracked texts with translations
        await MainActor.run {
            textTracker.updateTranslations(translations)
            
            // Clear texts from being translated set
            textsToTranslate.forEach { textsBeingTranslated.remove($0) }
            
            // Note: HybridTracker temporarily disabled
            
            if !translations.isEmpty {
                Logger.shared.log(.info, "✅ Successfully translated \(translations.count) new texts")
                Logger.shared.log(.info, "📊 TextTracker now has \(textTracker.trackedTexts.filter { $0.translation != nil }.count) translated texts out of \(textTracker.trackedTexts.count) total")
            }
        }
    }
}

// MARK: - Camera Preview View

struct CameraPreviewView: UIViewRepresentable {
    let cameraManager: CameraManager
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        
        // Create preview layer with session
        let previewLayer = AVCaptureVideoPreviewLayer(session: cameraManager.getCaptureSession())
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = CGRect.zero  // Start with zero frame
        
        view.layer.addSublayer(previewLayer)
        
        // Store preview layer for later updates
        view.layer.setValue(previewLayer, forKey: "previewLayer")
        
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        // Update preview layer frame to match view bounds
        DispatchQueue.main.async {
            if let previewLayer = uiView.layer.value(forKey: "previewLayer") as? AVCaptureVideoPreviewLayer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                previewLayer.frame = uiView.bounds
                CATransaction.commit()
                
                // Ensure connection is active
                if previewLayer.connection?.isActive == false {
                    Logger.shared.log(.warning, "Preview layer connection is not active")
                }
            }
        }
    }
}

// MARK: - Language Selector View

@available(iOS 18.0, *)
struct LanguageSelectorView: View {
    @Binding var selectedLanguage: String
    let currentTargetLanguage: String  // Pass current target language for localization
    @Environment(\.dismiss) var dismiss
    @State private var hapticFeedback = UIImpactFeedbackGenerator(style: .medium)
    @State private var installingLanguages: Set<String> = []
    @State private var installedLanguages: Set<String> = []
    
    let languages = [
        ("ko", "한국어", "🇰🇷"),
        ("en", "English", "🇺🇸"),
        ("ja", "日本語", "🇯🇵")
    ]
    
    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                // Language installation providers (hidden)
                ForEach(languages, id: \.0) { lang in
                    LanguageInstallationProvider(
                        targetLanguage: lang.0,
                        onInstallationStart: {
                            installingLanguages.insert(lang.0)
                        },
                        onInstallationComplete: { success in
                            installingLanguages.remove(lang.0)
                            if success {
                                installedLanguages.insert(lang.0)
                            }
                        }
                    )
                }
                
                ForEach(languages, id: \.0) { lang in
                    LanguageOptionRow(
                        code: lang.0,
                        name: lang.1,
                        emoji: lang.2,
                        isSelected: selectedLanguage == lang.0,
                        isInstalling: installingLanguages.contains(lang.0),
                        isInstalled: installedLanguages.contains(lang.0),
                        currentTargetLanguage: currentTargetLanguage,
                        onSelect: {
                            hapticFeedback.impactOccurred()
                            withAnimation(.easeInOut(duration: 0.2)) {
                                selectedLanguage = lang.0
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                dismiss()
                            }
                        }
                    )
                }
                
                Spacer()
                
                // Info text
                Text(LocalizationService.L("language_pack_auto_install"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .navigationTitle(LocalizationService.L("translation_target"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(LocalizationService.L("done")) { dismiss() }
                        .font(.headline)
                        .foregroundColor(.blue)
                }
            }
        }
        .onAppear {
            hapticFeedback.prepare()
        }
    }
}

struct LanguageOptionRow: View {
    let code: String
    let name: String
    let emoji: String
    let isSelected: Bool
    let isInstalling: Bool
    let isInstalled: Bool
    let currentTargetLanguage: String  // Pass current target language for localization
    let onSelect: () -> Void
    
    @State private var isPressed = false
    
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                Text(emoji)
                    .font(.system(size: 32))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(isSelected ? .white : .primary)
                    
                    Text(getLanguageDescription(code))
                        .font(.caption)
                        .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                }
                
                Spacer()
                
                // Status indicator
                if isInstalling {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: isSelected ? .white : .blue))
                        .scaleEffect(0.8)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .scaleEffect(isPressed ? 0.95 : 1.0)
                        .animation(.easeInOut(duration: 0.1), value: isPressed)
                } else if isInstalled {
                    Image(systemName: "checkmark.circle")
                        .font(.title2)
                        .foregroundColor(.green)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(
                        isSelected 
                        ? LinearGradient(
                            colors: [Color.blue, Color.blue.opacity(0.8)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        : LinearGradient(
                            colors: [Color(.systemGray6), Color(.systemGray5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isSelected ? Color.blue.opacity(0.3) : 
                                isInstalled ? Color.green.opacity(0.3) : Color.clear,
                                lineWidth: 2
                            )
                    )
                    .scaleEffect(isPressed ? 0.98 : 1.0)
                    .animation(.easeInOut(duration: 0.1), value: isPressed)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .onLongPressGesture(minimumDuration: 0, maximumDistance: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .disabled(isInstalling)
    }
    
    private func getLanguageDescription(_ code: String) -> String {
        if isInstalling {
            return LocalizationService.L("language_pack_installing")
        } else if isInstalled {
            // Show which languages can be translated to this target language
            switch code {
            case "ko": return "영어, 일본어 → 한국어"
            case "en": return "Korean, Japanese → English"
            case "ja": return "韓国語、英語 → 日本語"
            default: return "Translation ready"
            }
        } else {
            switch code {
            case "ko": return "카메라로 인식한 텍스트를 한국어로 번역"
            case "en": return "Translate recognized text to English"
            case "ja": return "認識したテキストを日本語に翻訳"
            default: return ""
            }
        }
    }
}

// MARK: - Language Installation Provider (for LanguageSelectorView)

@available(iOS 18.0, *)
struct LanguageInstallationProvider: View {
    let targetLanguage: String
    let onInstallationStart: (() -> Void)?
    let onInstallationComplete: ((Bool) -> Void)?
    
    var body: some View {
        // Create a simplified batch provider for just this target language
        VStack(spacing: 0) {
            let allLanguages = ["ko", "en", "ja"]
            ForEach(allLanguages.filter { $0 != targetLanguage }, id: \.self) { sourceLanguage in
                DynamicLanguagePackProvider(
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    onSessionReady: { _ in
                        // Session handling is done elsewhere
                    },
                    onInstallationStart: onInstallationStart,
                    onInstallationComplete: onInstallationComplete
                )
                
                DynamicLanguagePackProvider(
                    sourceLanguage: targetLanguage,
                    targetLanguage: sourceLanguage,
                    onSessionReady: { _ in
                        // Session handling is done elsewhere
                    },
                    onInstallationStart: onInstallationStart,
                    onInstallationComplete: onInstallationComplete
                )
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }
}
