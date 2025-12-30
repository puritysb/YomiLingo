//
//  SettingsView.swift
//  ViewLingo-Cam
//
//  Settings view for the app
//

import SwiftUI

@available(iOS 18.0, *)
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var languageService = LanguagePackService.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var showResetConfirmation = false
    @State private var selectedARMode: ARMode = .standard  // Temporary selection
    @State private var installingLanguages: Set<String> = []
    @State private var languagePackStatuses: [String: LanguagePackStatus] = [:]
    @State private var showOnDeviceModeAlert = false
    @State private var onDeviceModeEnabled = false
    
    enum LanguagePackStatus {
        case checking
        case installed
        case notInstalled
        case installing
        case unsupported
        case needsOnDeviceMode  // 설치됐지만 온디바이스 모드 필요
    }
    
    var body: some View {
        NavigationView {
            List {
                // On-Device Mode Status
                Section(LocalizationService.L("translation_mode")) {
                    HStack {
                        Image(systemName: "cpu")
                            .foregroundColor(.blue)
                        Text(LocalizationService.L("on_device_mode"))
                        Spacer()
                        if onDeviceModeEnabled {
                            Label(LocalizationService.L("enabled"), systemImage: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.caption)
                        } else {
                            Label(LocalizationService.L("disabled"), systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                        }
                    }
                    
                    if !onDeviceModeEnabled {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(LocalizationService.L("on_device_translation_instruction"))
                                .font(.caption)
                                .fontWeight(.medium)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text(LocalizationService.L("on_device_mode_instruction_1"))
                                Text(LocalizationService.L("on_device_mode_instruction_2"))
                                Text(LocalizationService.L("on_device_mode_instruction_3"))
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.leading)
                            
                            Button(action: openTranslateSettings) {
                                Label(LocalizationService.L("open_translation_settings"), systemImage: "arrow.up.forward.app")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
                
                // Language Settings
                Section(LocalizationService.L("language_settings")) {
                    HStack {
                        Text(LocalizationService.L("target_language"))
                        Spacer()
                        HStack {
                            Text(languageService.getLanguageEmoji(appState.targetLanguage))
                            Text(languageService.getLanguageName(appState.targetLanguage))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Language pack status with real-time checking
                    ForEach(["ko", "en", "ja"], id: \.self) { lang in
                        LanguagePackRow(
                            languageCode: lang,
                            languageName: languageService.getLanguageName(lang),
                            languageEmoji: languageService.getLanguageEmoji(lang),
                            status: languagePackStatuses[lang] ?? .checking,
                            targetLanguage: appState.targetLanguage,
                            onInstallTapped: {
                                installLanguagePack(lang)
                            }
                        )
                    }
                    
                    // Note: Language pack installation is handled by CameraView's LanguageSelectorView
                    // Settings view shows current status only - actual installation happens in camera
                }
                
                // Source Language Selection
                Section(header: Text("번역 소스 언어")) {
                    Text("화면에서 인식할 언어 선택 (최소 1개)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    ForEach(appState.availableSourceLanguages, id: \.0) { langInfo in
                        let (code, name, emoji) = langInfo
                        
                        HStack {
                            // Checkbox
                            Image(systemName: appState.enabledSourceLanguages.contains(code) ? "checkmark.square.fill" : "square")
                                .foregroundColor(appState.enabledSourceLanguages.contains(code) ? .blue : .gray)
                                .font(.system(size: 22))
                            
                            // Language info
                            Text(emoji)
                                .font(.title2)
                            Text(name)
                                .font(.body)
                            
                            Spacer()
                            
                            // Show if it's the target language (disabled)
                            if code == appState.targetLanguage {
                                Text("(대상 언어)")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                            }
                            // Show if French needs language pack
                            else if code == "fr" && (languagePackStatuses[code] ?? .checking) != .installed {
                                Text("(언어팩 필요)")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Can't toggle if it's the target language
                            guard code != appState.targetLanguage else { return }
                            appState.toggleSourceLanguage(code)
                        }
                        .disabled(code == appState.targetLanguage)
                        .opacity(code == appState.targetLanguage ? 0.5 : 1.0)
                    }
                }
                
                
                // About
                Section(LocalizationService.L("information")) {
                    HStack {
                        Text(LocalizationService.L("version"))
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text(LocalizationService.L("ios_minimum_version"))
                        Spacer()
                        Text("18.0")
                            .foregroundColor(.secondary)
                    }
                }
                
                // AR Mode Settings - HIDDEN FOR INITIAL RELEASE
                #if DEBUG
                // Show AR mode settings only in debug builds for testing
                Section(LocalizationService.L("ar_mode")) {
                    Picker(LocalizationService.L("ar_tracking_method"), selection: $selectedARMode) {
                        ForEach(ARMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue)
                                .tag(mode)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    .padding(.vertical, 4)
                    
                    // Show description of selected mode
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: selectedARMode == .standard ? "rectangle.on.rectangle" : "cube.transparent")
                                .foregroundColor(selectedARMode == .standard ? .blue : .orange)
                            Text(selectedARMode.localizedDescription())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        // Show experimental note for ARKit mode
                        if selectedARMode == .arkit {
                            Text(LocalizationService.L("arkit_experimental_note"))
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.8))
                                .padding(.leading, 24)
                        }
                    }
                    .padding(.vertical, 2)
                }
                #else
                // Production build - AR mode hidden
                // Section(LocalizationService.L("ar_mode", appState.targetLanguage)) {
                //     Picker(LocalizationService.L("ar_tracking_method", appState.targetLanguage), selection: $selectedARMode) {
                //         ForEach(ARMode.allCases, id: \.self) { mode in
                //             Text(mode.rawValue)
                //                 .tag(mode)
                //         }
                //     }
                //     .pickerStyle(SegmentedPickerStyle())
                //     .padding(.vertical, 4)
                //     
                //     // Show description of selected mode
                //     VStack(alignment: .leading, spacing: 4) {
                //         HStack {
                //             Image(systemName: selectedARMode == .standard ? "rectangle.on.rectangle" : "cube.transparent")
                //                 .foregroundColor(selectedARMode == .standard ? .blue : .orange)
                //             Text(selectedARMode.localizedDescription())
                //                 .font(.caption)
                //                 .foregroundColor(.secondary)
                //         }
                //         
                //         // Show experimental note for ARKit mode
                //         if selectedARMode == .arkit {
                //             Text(LocalizationService.L("arkit_experimental_note", appState.targetLanguage))
                //                 .font(.caption2)
                //                 .foregroundColor(.secondary.opacity(0.8))
                //                 .padding(.leading, 24)
                //         }
                //     }
                //     .padding(.vertical, 2)
                // }
                #endif
                
                // Actions
                Section {
                    Button(action: { showResetConfirmation = true }) {
                        Label(LocalizationService.L("reset_app_settings"), systemImage: "arrow.counterclockwise")
                            .foregroundColor(.orange)
                    }
                }
                
                // Language Pack Management Guide
                Section(LocalizationService.L("language_pack_management")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LocalizationService.L("language_pack_manage_instruction"))
                            .font(.caption)
                            .fontWeight(.medium)
                        
                        Text(LocalizationService.L("language_pack_manage_path"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text(LocalizationService.L("language_pack_manage_description"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(LocalizationService.L("settings"))
            .navigationBarItems(trailing: Button(LocalizationService.L("done")) { 
                #if DEBUG
                // Allow AR mode change in debug builds
                if selectedARMode != appState.arMode {
                    Logger.shared.log(.info, "Applying AR mode change: \(appState.arMode.rawValue) -> \(selectedARMode.rawValue)")
                    appState.setARMode(selectedARMode)
                }
                #else
                // AR mode change disabled for production
                #endif
                dismiss() 
            })
        }
        .alert(LocalizationService.L("reset_app_settings"), isPresented: $showResetConfirmation) {
            Button(LocalizationService.L("cancel"), role: .cancel) { }
            Button(LocalizationService.L("reset"), role: .destructive) {
                resetAppSettings()
                dismiss()
            }
        } message: {
            Text(LocalizationService.L("reset_app_settings_message"))
        }
        .onAppear {
            // Initialize selected mode with current mode
            selectedARMode = appState.arMode
            Logger.shared.log(.info, "Settings opened with AR mode: \(appState.arMode.rawValue)")
            
            // Check language pack statuses and on-device mode
            Task {
                await checkAllLanguageStatuses()
                await checkOnDeviceMode()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // Refresh language pack status when returning to the app
            Task {
                await checkAllLanguageStatuses()
            }
        }
        .alert(LocalizationService.L("on_device_mode_required"), isPresented: $showOnDeviceModeAlert) {
            Button(LocalizationService.L("open_settings")) {
                openTranslateSettings()
            }
            Button(LocalizationService.L("cancel"), role: .cancel) { }
        } message: {
            Text(LocalizationService.L("on_device_mode_alert_message"))
        }
    }
    
    // MARK: - Helper Methods
    
    private func checkAllLanguageStatuses() async {
        let languages = ["ko", "en", "ja"]
        
        for lang in languages {
            await MainActor.run {
                languagePackStatuses[lang] = .checking
            }
        }
        
        // Check status for each language
        for lang in languages {
            await checkLanguageStatus(lang)
        }
    }
    
    private func checkLanguageStatus(_ languageCode: String) async {
        // Get overall status for this language by checking if any required pairs are installed
        await languageService.checkStatusForTarget(languageCode)
        
        // Analyze the pack statuses to determine overall language status
        let requiredPairs = languageService.getRequiredPairs(for: languageCode)
        
        await MainActor.run {
            var installedCount = 0
            var notInstalledCount = 0
            var unsupportedCount = 0
            
            for pair in requiredPairs {
                switch languageService.packStatuses[pair] {
                case .installed:
                    installedCount += 1
                case .notInstalled:
                    notInstalledCount += 1
                case .unsupported:
                    unsupportedCount += 1
                default:
                    break
                }
            }
            
            // Determine overall status
            if installedCount == requiredPairs.count {
                // All required pairs are installed
                languagePackStatuses[languageCode] = .installed
            } else if installedCount > 0 {
                // Some pairs are installed but not all
                // This is actually fine - we can still translate with what we have
                languagePackStatuses[languageCode] = .installed
            } else if unsupportedCount == requiredPairs.count {
                // All pairs are unsupported
                languagePackStatuses[languageCode] = .unsupported
            } else {
                // No pairs installed, but some are supported
                languagePackStatuses[languageCode] = .notInstalled
            }
            
            Logger.shared.log(.info, "Language \(languageCode) status: \(languagePackStatuses[languageCode] ?? .checking) (installed: \(installedCount)/\(requiredPairs.count))")
        }
    }
    
    private func checkOnDeviceMode() async {
        // Check if on-device mode is enabled by checking if any translations are working
        await MainActor.run {
            // If we have ANY installed language packs that are working, on-device mode is enabled
            let hasWorkingPacks = languageService.packStatuses.values.contains(.installed)
            
            // Also check if we've had recent translation errors
            let hasRecentErrors = TranslationService().missingLanguagePacks.count > 0
            
            // On-device mode is enabled if we have working packs and no recent errors
            onDeviceModeEnabled = hasWorkingPacks && !hasRecentErrors
        }
    }
    
    private func openTranslateSettings() {
        // iOS doesn't allow opening specific system settings
        // We can only open our app's settings page
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        
        // Show instruction alert after a brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            showOnDeviceModeAlert = true
        }
    }
    
    private func installLanguagePack(_ languageCode: String) {
        Logger.shared.log(.info, "User tapped to install language pack for: \(languageCode)")
        
        // Check if on-device mode is needed first
        if !onDeviceModeEnabled {
            showOnDeviceModeAlert = true
            return
        }
        
        // For now, just show that installation is not available in settings
        // Actual installation happens through CameraView's LanguageSelectorView
        // This is a limitation - settings can only show status, not trigger installation
        Logger.shared.log(.info, "Language pack installation should be done through camera view language selector")
    }
    
    private func resetAppSettings() {
        Logger.shared.log(.info, "User requested app settings reset")
        
        // Reset app state
        appState.resetForTesting()
        
        // Clear language pack status cache
        languagePackStatuses.removeAll()
        
        // Reset language service (this will clear any cached statuses)
        // Note: We cannot delete actual language packs - only Apple can manage those
        
        Logger.shared.log(.info, "App settings reset completed - language packs remain in iOS system")
    }
}

// MARK: - Language Pack Row Component

@available(iOS 18.0, *)
struct LanguagePackRow: View {
    let languageCode: String
    let languageName: String
    let languageEmoji: String
    let status: SettingsView.LanguagePackStatus
    let targetLanguage: String  // Added for localization
    let onInstallTapped: () -> Void
    
    var body: some View {
        HStack {
            Text(languageEmoji)
                .font(.title2)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(languageName)
                    .font(.body)
                    .fontWeight(.medium)
                
                Text(statusDescription)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
            
            Spacer()
            
            statusIcon
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Installation not available in settings - redirect to camera
            Logger.shared.log(.info, "User tapped language pack row - installation should be done through camera")
        }
    }
    
    private var statusDescription: String {
        switch status {
        case .checking:
            return LocalizationService.L("checking_status")
        case .installed:
            return LocalizationService.L("translation_pack_installed")
        case .needsOnDeviceMode:
            return LocalizationService.L("needs_on_device_mode")
        case .notInstalled:
            return LocalizationService.L("available_in_camera")
        case .installing:
            return LocalizationService.L("installing")
        case .unsupported:
            return LocalizationService.L("not_supported")
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .checking:
            return .secondary
        case .installed:
            return .green
        case .needsOnDeviceMode:
            return .orange
        case .notInstalled:
            return .blue
        case .installing:
            return .orange
        case .unsupported:
            return .secondary
        }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .checking:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(0.8)
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.title2)
        case .needsOnDeviceMode:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.title2)
        case .notInstalled:
            Image(systemName: "arrow.down.circle")
                .foregroundColor(.blue)
                .font(.title2)
        case .installing:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .orange))
                .scaleEffect(0.8)
        case .unsupported:
            Image(systemName: "xmark.circle")
                .foregroundColor(.secondary)
                .font(.title2)
        }
    }
}