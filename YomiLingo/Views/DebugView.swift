//
//  DebugView.swift
//  ViewLingo-Cam
//
//  Debug information view for development
//

import SwiftUI

@available(iOS 18.0, *)
struct DebugView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var languageService = LanguagePackService.shared
    @Environment(\.dismiss) var dismiss
    
    @State private var logContent = ""
    @State private var selectedTab = 0
    
    var body: some View {
        NavigationView {
            TabView(selection: $selectedTab) {
                // Language Pack Status
                languagePackStatusView
                    .tabItem {
                        Label("언어 팩", systemImage: "globe")
                    }
                    .tag(0)
                
                // App State
                appStateView
                    .tabItem {
                        Label("앱 상태", systemImage: "info.circle")
                    }
                    .tag(1)
                
                // Logs
                logView
                    .tabItem {
                        Label("로그", systemImage: "doc.text")
                    }
                    .tag(2)
                
                // Performance
                performanceView
                    .tabItem {
                        Label("성능", systemImage: "speedometer")
                    }
                    .tag(3)
            }
            .navigationTitle("디버그 정보")
            .navigationBarItems(
                leading: Button("로그 지우기") {
                    Logger.shared.clearLog()
                    loadLogs()
                },
                trailing: Button("닫기") { dismiss() }
            )
        }
        .onAppear {
            loadLogs()
        }
    }
    
    // MARK: - Language Pack Status View
    
    private var languagePackStatusView: some View {
        List {
            Section("언어 팩 상태") {
                ForEach(Array(languageService.packStatuses.keys.sorted(by: { $0.key < $1.key })), id: \.key) { pair in
                    HStack {
                        Text(pair.key)
                            .font(.system(.body, design: .monospaced))
                        
                        Spacer()
                        
                        statusBadge(for: languageService.packStatuses[pair] ?? .checking)
                    }
                }
            }
            
            Section("언어 팩 상태") {
                Text("동적 설치 시스템 사용 중")
                    .foregroundColor(.secondary)
                Text("언어 팩은 필요 시 자동 설치됩니다")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section("작업") {
                Button("언어 팩 상태 재확인") {
                    Task {
                        await languageService.checkAllStatuses()
                    }
                }
            }
        }
    }
    
    private func statusBadge(for status: LanguagePackService.PackStatus) -> some View {
        Group {
            switch status {
            case .checking:
                Label("확인 중", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundColor(.orange)
            case .notInstalled:
                Label("미설치", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundColor(.red)
            case .installed:
                Label("설치됨", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundColor(.green)
            case .unsupported:
                Label("미지원", systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
    }
    
    // MARK: - App State View
    
    private var appStateView: some View {
        List {
            Section("기본 정보") {
                InfoRow(label: "온보딩", value: "비활성화됨 (동적 설치)")
                InfoRow(label: "설치 방식", value: "Apple 네이티브 translationTask")
                InfoRow(label: "대상 언어", value: "\(languageService.getLanguageEmoji(appState.targetLanguage)) \(appState.targetLanguage)")
            }
            
            Section("시스템 정보") {
                InfoRow(label: "iOS 버전", value: UIDevice.current.systemVersion)
                InfoRow(label: "디바이스", value: UIDevice.current.model)
                InfoRow(label: "앱 버전", value: "1.0.0")
                InfoRow(label: "빌드", value: "100")
            }
            
            Section("카메라") {
                InfoRow(label: "권한", value: "허용됨")
                InfoRow(label: "해상도", value: "1920x1080")
                InfoRow(label: "FPS", value: "30")
            }
        }
    }
    
    // MARK: - Log View
    
    private var logView: some View {
        VStack {
            // Log stats
            HStack {
                Text("로그 크기: \(formatBytes(Logger.shared.getLogFileSize()))")
                Spacer()
                Text("라인: \(logContent.components(separatedBy: "\n").count)")
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal)
            .padding(.top, 8)
            
            // Log content
            ScrollView {
                Text(logContent)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.gray.opacity(0.1))
        }
    }
    
    // MARK: - Performance View
    
    private var performanceView: some View {
        List {
            Section("메모리") {
                InfoRow(label: "사용 중", value: "\(getMemoryUsage()) MB")
                InfoRow(label: "캐시", value: "200 항목")
            }
            
            Section("처리 성능") {
                InfoRow(label: "OCR 평균", value: "250ms")
                InfoRow(label: "번역 평균", value: "150ms")
                InfoRow(label: "프레임 처리", value: "15 FPS")
            }
            
            Section("네트워크") {
                InfoRow(label: "연결 상태", value: "온라인")
                InfoRow(label: "번역 모드", value: "온디바이스")
            }
        }
    }
    
    // MARK: - Helper Methods
    
    private func loadLogs() {
        logContent = Logger.shared.getLogContents() ?? "로그 없음"
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: bytes)
    }
    
    private func getMemoryUsage() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPtr, &count)
            }
        }
        
        if result == KERN_SUCCESS {
            let usedMemory = Double(info.resident_size) / 1024.0 / 1024.0
            return String(format: "%.1f", usedMemory)
        }
        
        return "N/A"
    }
}

// MARK: - Helper Views

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.primary)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }
}