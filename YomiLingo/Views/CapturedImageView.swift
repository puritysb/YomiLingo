//
//  CapturedImageView.swift
//  ViewLingo-Cam
//
//  Shows captured image with translation overlay
//

import SwiftUI
import UIKit

@available(iOS 18.0, *)
struct CapturedImageView: View {
    let image: UIImage
    @Binding var trackedTexts: [TrackedText]
    @Binding var isPresented: Bool
    let appState: AppState
    let translationCoordinator: TranslationCoordinator  // Passed from parent
    
    @StateObject private var ocrService = OCRService()
    @State private var isProcessing = true
    @State private var showTranslations = true
    @State private var showShareSheet = false
    @State private var processingStatus = ""
    @State private var translationProgress = 0.0
    
    // Zoom and pan states
    @State private var currentScale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var currentOffset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    
    var body: some View {
        ZStack {
            // Zoomable content group
            GeometryReader { geometry in
                ZStack {
                    // Captured image
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                    
                    // Translation overlay with interactive boxes
                    if !isProcessing && showTranslations {
                        let imageRect = calculateImageRect(
                            imageSize: image.size,
                            containerSize: geometry.size
                        )
                        
                        // Create a ZStack positioned at the image rect
                        ZStack {
                            ForEach(trackedTexts) { tracked in
                            // Show both translated and untranslated texts (like Live mode)
                            if let translation = tracked.translation {
                                // Use BoxTranslation for consistency with Live mode
                                BoxTranslation(
                                    originalText: tracked.text,
                                    translatedText: translation,
                                    boundingBox: tracked.boundingBox,  // Already normalized
                                    confidence: tracked.confidence,
                                    screenSize: CGSize(width: imageRect.width, height: imageRect.height),  // Use imageRect size
                                    qualityScore: tracked.qualityScore,
                                    suspicionLevel: tracked.suspicionLevel,
                                    arMode: appState.arMode,
                                    isVerticalText: tracked.isVerticalText,
                                    sourceLanguage: tracked.sourceLanguage,
                                    isCapturedImage: true  // Enable Y-axis fine-tuning
                                )
                            } else {
                                // Show original text for failed translations (like Live mode)
                                BoxTranslation(
                                    originalText: tracked.text,
                                    translatedText: tracked.text,  // Show original as "translation"
                                    boundingBox: tracked.boundingBox,  // Already normalized
                                    confidence: tracked.confidence,
                                    screenSize: CGSize(width: imageRect.width, height: imageRect.height),  // Use imageRect size
                                    qualityScore: tracked.qualityScore,
                                    suspicionLevel: tracked.suspicionLevel,
                                    arMode: appState.arMode,
                                    isVerticalText: tracked.isVerticalText,
                                    sourceLanguage: tracked.sourceLanguage,
                                    isCapturedImage: true  // Enable Y-axis fine-tuning
                                )
                            }
                        }
                        }
                        .frame(width: imageRect.width, height: imageRect.height)
                        .position(x: imageRect.midX, y: imageRect.midY)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(currentScale)
                .offset(currentOffset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            let delta = value / lastScale
                            lastScale = value
                            currentScale = min(max(currentScale * delta, 0.5), 5.0) // Limit scale between 0.5x and 5x
                        }
                        .onEnded { _ in
                            lastScale = 1.0
                            // Snap to 1x if close
                            withAnimation(.spring()) {
                                if currentScale > 0.9 && currentScale < 1.1 {
                                    currentScale = 1.0
                                    currentOffset = .zero
                                }
                            }
                        }
                        .simultaneously(with:
                            DragGesture()
                                .onChanged { value in
                                    if currentScale > 1.0 {
                                        currentOffset = CGSize(
                                            width: lastOffset.width + value.translation.width,
                                            height: lastOffset.height + value.translation.height
                                        )
                                    }
                                }
                                .onEnded { _ in
                                    lastOffset = currentOffset
                                    // Limit offset to prevent image from going too far off-screen
                                    withAnimation(.spring()) {
                                        let maxOffset = geometry.size.width * (currentScale - 1) / 2
                                        currentOffset.width = min(max(currentOffset.width, -maxOffset), maxOffset)
                                        currentOffset.height = min(max(currentOffset.height, -maxOffset), maxOffset)
                                        lastOffset = currentOffset
                                    }
                                }
                        )
                )
                .onTapGesture(count: 2) {
                    // Double tap to zoom in/out
                    withAnimation(.spring()) {
                        if currentScale > 1.5 {
                            currentScale = 1.0
                            currentOffset = .zero
                            lastOffset = .zero
                        } else {
                            currentScale = 2.0
                        }
                    }
                }
            }
            .ignoresSafeArea()
            
            // Processing indicator
            if isProcessing {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                
                VStack(spacing: 20) {
                    if translationProgress > 0 {
                        // Translation progress indicator
                        VStack(spacing: 12) {
                            ProgressView(value: translationProgress, total: 1.0)
                                .progressViewStyle(LinearProgressViewStyle(tint: .white))
                                .frame(width: 200)
                            
                            Text(processingStatus)
                                .font(.headline)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                        }
                    } else {
                        // OCR processing indicator
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            
                            Text(processingStatus)
                                .font(.headline)
                                .foregroundColor(.white)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
            }
            
            // Top control bar
            VStack {
                HStack {
                    // Close button
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    
                    Spacer()
                    
                    // Zoom reset button (show only when zoomed)
                    if currentScale != 1.0 {
                        Button(action: {
                            withAnimation(.spring()) {
                                currentScale = 1.0
                                currentOffset = .zero
                                lastOffset = .zero
                            }
                        }) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.title2)
                                .foregroundColor(.white)
                                .padding(12)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                    }
                    
                    // Toggle translations visibility
                    Button(action: { showTranslations.toggle() }) {
                        Image(systemName: showTranslations ? "eye.fill" : "eye.slash.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    
                    // Share button
                    Button(action: { showShareSheet = true }) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(12)
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                }
                .padding()
                
                Spacer()
            }
        }
        .statusBar(hidden: true)
        .onAppear {
            performHighQualityOCR()
        }
        .sheet(isPresented: $showShareSheet) {
            if let fileURL = createCompositeImage() {
                ShareSheet(items: [fileURL])
                    .onDisappear {
                        // Clean up temporary file after sharing
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            try? FileManager.default.removeItem(at: fileURL)
                            Logger.shared.log(.debug, "Cleaned up temporary share file")
                        }
                    }
            }
        }
        // Hidden TranslationExecutor to process translation requests
        .background(
            TranslationExecutor(coordinator: translationCoordinator)
                .frame(width: 0, height: 0)
                .opacity(0)
        )
    }
    
    
    private func performHighQualityOCR() {
        Task {
            // Set initial status
            await MainActor.run {
                processingStatus = LocalizationService.L("ocr_processing")
            }
            
            // Set to accurate mode for best quality
            ocrService.setRecognitionMode(.accurate)
            ocrService.arMode = appState.arMode
            ocrService.targetLanguage = appState.targetLanguage  // Critical: Set target language for proper OCR prioritization
            
            // Convert UIImage to CIImage
            guard let ciImage = CIImage(image: image) else {
                await MainActor.run {
                    isProcessing = false
                }
                return
            }
            
            // Perform OCR
            await ocrService.processImage(ciImage)
            
            // Create text tracker and process results
            let textTracker = TextTracker()
            // For manual capture, always use fast tracking (like ARKit mode)
            textTracker.arMode = .arkit  // This ensures immediate text tracking
            
            await MainActor.run {
                textTracker.processNewTexts(ocrService.recognizedTexts)
                // Force immediate promotion of all recognized texts for manual capture
                if textTracker.trackedTexts.isEmpty && !ocrService.recognizedTexts.isEmpty {
                    // If no texts were tracked, directly convert OCR results
                    trackedTexts = ocrService.recognizedTexts.map { ocrText in
                        TrackedText(
                            text: ocrText.text,
                            boundingBox: ocrText.boundingBox,
                            confidence: ocrText.confidence
                        )
                    }
                } else {
                    trackedTexts = textTracker.trackedTexts
                }
            }
            
            // Update status for translation phase
            await MainActor.run {
                processingStatus = LocalizationService.L("processing")
                translationProgress = 0.1
            }
            
            // Wait for translation sessions to be ready, then translate
            await waitForTranslationAndProcess()
        }
    }
    
    private func waitForTranslationAndProcess() async {
        let maxWaitTime: TimeInterval = 5.0  // Maximum 5 seconds wait
        let checkInterval: TimeInterval = 0.1  // Check every 100ms
        let startTime = Date()
        
        Logger.shared.log(.info, "Waiting for translation sessions to be ready for target: \(appState.targetLanguage)")
        
        // Wait for translation to become available
        while Date().timeIntervalSince(startTime) < maxWaitTime {
            let elapsed = Date().timeIntervalSince(startTime)
            await MainActor.run {
                processingStatus = LocalizationService.L("processing")
                translationProgress = 0.1 + (elapsed / maxWaitTime) * 0.2 // 0.1 to 0.3
            }
            
            // Check if language packs are installed
            let hasInstalledPacks = !translationCoordinator.installedLanguagePairs.isEmpty
            if hasInstalledPacks {
                Logger.shared.log(.info, "Translation ready after \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
                break
            }
            
            // Wait a bit before checking again
            try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
        }
        
        // Proceed with translation
        if !translationCoordinator.installedLanguagePairs.isEmpty {
            await performTranslationWithRetry()
        } else {
            await MainActor.run {
                processingStatus = LocalizationService.L("processing")
                translationProgress = 1.0
                Logger.shared.log(.warning, "Translation not available for captured image after \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s wait")
            }
            
            // Show error for a moment then finish
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            await MainActor.run {
                isProcessing = false
            }
        }
    }
    
    private func performTranslationWithRetry() async {
        let maxRetries = 2
        var attempt = 1
        var finalTranslations: [String: String] = [:]
        var remainingTexts = trackedTexts.map { $0.text }
        
        // Detect languages for all texts
        let allTexts = trackedTexts.map { $0.text }
        let textsByLanguage = translationCoordinator.detectLanguages(for: allTexts)
        let dominantLanguage = textsByLanguage.keys.first
        
        Logger.shared.log(.info, """
            🌍 Language Context Analysis:
              - Total texts: \(allTexts.count)
              - Dominant language: \(dominantLanguage ?? "undetermined")
              - Target language: \(appState.targetLanguage)
            """)
        
        let initialTextCount = remainingTexts.count  // Track initial count for comparison
        
        while attempt <= maxRetries && !remainingTexts.isEmpty {
            await MainActor.run {
                processingStatus = LocalizationService.L("translating")
                translationProgress = 0.3 + (Double(attempt - 1) / Double(maxRetries)) * 0.6 // 0.3 to 0.9
            }
            
            Logger.shared.log(.info, """
                🔄 Translation attempt \(attempt)/\(maxRetries):
                  - Target language: \(appState.targetLanguage)
                  - Context hint: \(dominantLanguage ?? "none")
                  - Texts to translate: \(remainingTexts.count)
                  - Sample texts: \(remainingTexts.prefix(3).map { "'\($0.prefix(20))...'" }.joined(separator: ", "))
                """)
            
            if attempt > 1 {
                // Wait a bit before retrying
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
            
            // Request translations using coordinator with timeout
            var translations: [String: String] = [:]
            
            // Detect languages for remaining texts
            let textsLangMap = translationCoordinator.detectLanguages(for: remainingTexts)
            
            // Request translations for each language using async/await
            let targetLang = appState.targetLanguage
            await withTaskGroup(of: [String: String].self) { group in
                for (sourceLang, texts) in textsLangMap {
                    // Skip same-language translations
                    if sourceLang == targetLang {
                        Logger.shared.log(.warning, "Skipping same-language texts: \(sourceLang)→\(targetLang) (\(texts.count) texts)")
                        continue
                    }
                    
                    if let enabledSources = translationCoordinator.appState?.enabledSourceLanguages,
                       enabledSources.contains(sourceLang) {
                        group.addTask { @MainActor in
                            await withCheckedContinuation { continuation in
                                translationCoordinator.requestTranslation(
                                    texts: texts,
                                    from: sourceLang,
                                    to: targetLang
                                ) { results in
                                    continuation.resume(returning: results)
                                }
                            }
                        }
                    }
                }
                
                // Collect all results with timeout
                for await result in group {
                    for (text, translation) in result {
                        translations[text] = translation
                    }
                }
            }
            
            // Merge successful translations
            for (text, translation) in translations {
                if !translation.isEmpty {
                    finalTranslations[text] = translation
                }
            }
            
            // Update remaining texts to only those that failed
            remainingTexts = remainingTexts.filter { text in
                finalTranslations[text] == nil
            }
            
            Logger.shared.log(.info, """
                📊 Attempt \(attempt) results:
                  - Successfully translated: \(translations.count)
                  - Still remaining: \(remainingTexts.count)
                """)
            
            // Check if no progress was made (all texts might be same-language)
            if translations.isEmpty && remainingTexts.count == initialTextCount {
                Logger.shared.log(.warning, "No progress made in translation attempt - all texts may be same-language or unsupported")
                break  // Exit retry loop to prevent infinite loop
            }
            
            attempt += 1
        }
        
        await MainActor.run {
            // Filter tracked texts to only keep those that need translation
            var filteredTrackedTexts: [TrackedText] = []
            var translatedCount = 0
            var skippedCount = 0
            var failedTexts: [String] = []
            
            for tracked in trackedTexts {
                if let translation = finalTranslations[tracked.text] {
                    // Only add if translation is different from original
                    // (TranslationCoordinator should have already filtered same-language texts)
                    if translation != tracked.text {
                        var updatedTracked = tracked
                        updatedTracked.translation = translation
                        filteredTrackedTexts.append(updatedTracked)
                        translatedCount += 1
                        Logger.shared.log(.debug, "✅ Final result: '\(tracked.text.prefix(20))...' → '\(translation.prefix(20))...'")
                    } else {
                        skippedCount += 1
                        Logger.shared.log(.debug, "⏭️ Skipped (same text): '\(tracked.text.prefix(20))...'")
                    }
                } else {
                    // Check if this text was skipped because it's in target language or is pure numbers
                    let isPureNumber = tracked.text.range(of: "^[0-9.,\\s]+$", options: .regularExpression) != nil
                    let detectedLangs = translationCoordinator.detectLanguages(for: [tracked.text])
                    let sourceLanguage = detectedLangs.keys.first ?? "unknown"
                    
                    if sourceLanguage == appState.targetLanguage || isPureNumber {
                        skippedCount += 1
                        Logger.shared.log(.debug, "⏭️ Skipped (no translation needed): '\(tracked.text.prefix(20))...'")
                    } else {
                        failedTexts.append(tracked.text)
                        Logger.shared.log(.debug, "❌ Final failure: '\(tracked.text.prefix(20))...'")
                    }
                }
            }
            
            // Update tracked texts with only those that have meaningful translations
            trackedTexts = filteredTrackedTexts
            
            // Show simple completion status
            processingStatus = LocalizationService.L("processing_complete")
            translationProgress = 1.0
            
            Logger.shared.log(.info, """
                📊 Captured image translation completed (with retry):
                  - Successfully translated: \(translatedCount)
                  - Skipped (no translation needed): \(skippedCount)
                  - Failed translations: \(failedTexts.count)
                  - Total displayed: \(filteredTrackedTexts.count)
                  - Failed texts: \(failedTexts.prefix(3).map { "'\($0.prefix(15))...'" }.joined(separator: ", "))
                """)
        }
        
        // Wait a moment then finish processing
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        await MainActor.run {
            isProcessing = false
        }
    }
    
    private func calculateImageRect(imageSize: CGSize, containerSize: CGSize) -> CGRect {
        // Calculate aspect ratios
        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height
        
        var displayRect: CGRect
        if imageAspect > containerAspect {
            // Image is wider - letterbox (black bars top/bottom)
            let displayHeight = containerSize.width / imageAspect
            let yOffset = (containerSize.height - displayHeight) / 2
            displayRect = CGRect(x: 0, y: yOffset, width: containerSize.width, height: displayHeight)
        } else {
            // Image is taller - pillarbox (black bars left/right)
            let displayWidth = containerSize.height * imageAspect
            let xOffset = (containerSize.width - displayWidth) / 2
            displayRect = CGRect(x: xOffset, y: 0, width: displayWidth, height: containerSize.height)
        }
        
        return displayRect
    }
    
    private func createCompositeImage() -> URL? {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        
        let compositeImage = renderer.image { context in
            // Draw original image
            image.draw(at: .zero)
            
            // Draw translation overlays
            let _ = image.size.width / UIScreen.main.bounds.width
            
            for tracked in trackedTexts where tracked.translation != nil {
                let screenBox = CGRect(
                    x: tracked.boundingBox.origin.x * image.size.width,
                    y: (1 - tracked.boundingBox.maxY) * image.size.height,
                    width: tracked.boundingBox.width * image.size.width,
                    height: tracked.boundingBox.height * image.size.height
                )
                
                // Draw background
                context.cgContext.setFillColor(UIColor.systemBlue.withAlphaComponent(0.85).cgColor)
                let path = UIBezierPath(roundedRect: screenBox, cornerRadius: 4)
                context.cgContext.addPath(path.cgPath)
                context.cgContext.fillPath()
                
                // Draw text
                let paragraphStyle = NSMutableParagraphStyle()
                paragraphStyle.alignment = .center
                
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: screenBox.height * 0.6, weight: .medium),
                    .foregroundColor: UIColor.white,
                    .paragraphStyle: paragraphStyle
                ]
                
                let text = tracked.translation ?? ""
                let textRect = screenBox.insetBy(dx: 4, dy: 4)
                text.draw(in: textRect, withAttributes: attributes)
            }
        }
        
        // Convert to JPEG data with compression for better compatibility
        guard let jpegData = compositeImage.jpegData(compressionQuality: 0.8) else {
            Logger.shared.log(.error, "Failed to convert image to JPEG data")
            return nil
        }
        
        // Check size and compress more if needed (max 1MB for reliability)
        let finalData: Data
        if jpegData.count > 1_000_000 {
            // If larger than 1MB, compress more
            if let compressedData = compositeImage.jpegData(compressionQuality: 0.5) {
                finalData = compressedData
                Logger.shared.log(.info, "Image compressed to \(compressedData.count / 1024)KB for sharing")
            } else {
                finalData = jpegData
            }
        } else {
            finalData = jpegData
            Logger.shared.log(.info, "Image size: \(jpegData.count / 1024)KB")
        }
        
        // Save to temporary file
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileName = "ViewLingo_\(Date().timeIntervalSince1970).jpg"
        let fileURL = tempDirectory.appendingPathComponent(fileName)
        
        do {
            try finalData.write(to: fileURL)
            Logger.shared.log(.info, "Saved share image to: \(fileURL.path)")
            return fileURL
        } catch {
            Logger.shared.log(.error, "Failed to save image to temp file: \(error)")
            return nil
        }
    }
    
    // Convert absolute bounding box to normalized coordinates for BoxTranslation
    private func convertToNormalizedBox(_ absoluteBox: CGRect, imageRect: CGRect) -> CGRect {
        return CGRect(
            x: absoluteBox.origin.x / imageRect.width,
            y: absoluteBox.origin.y / imageRect.height, 
            width: absoluteBox.width / imageRect.width,
            height: absoluteBox.height / imageRect.height
        )
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}