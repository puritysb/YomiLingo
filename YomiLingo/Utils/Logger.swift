//
//  Logger.swift
//  ViewLingo-Cam
//
//  Comprehensive logging system for debugging
//

import Foundation
import os.log

class Logger {
    static let shared = Logger()
    
    enum Level: String, Comparable {
        case debug = "🔍 DEBUG"
        case info = "ℹ️ INFO"
        case warning = "⚠️ WARN"
        case error = "❌ ERROR"
        
        // Define comparison for log level filtering
        static func < (lhs: Level, rhs: Level) -> Bool {
            let order: [Level] = [.debug, .info, .warning, .error]
            guard let lhsIndex = order.firstIndex(of: lhs),
                  let rhsIndex = order.firstIndex(of: rhs) else {
                return false
            }
            return lhsIndex < rhsIndex
        }
    }
    
    private let osLog = OSLog(subsystem: "com.viewlingo.cam", category: "ViewLingoCam")
    private let fileURL: URL?
    private let dateFormatter = DateFormatter()
    
    // Minimum log level for release builds
    #if DEBUG
    private let minLogLevel: Level = .debug  // Show all logs in debug
    private let enableFileLogging = true
    private let enableConsoleLogging = true
    #else
    private let minLogLevel: Level = .error  // Only errors in release
    private let enableFileLogging = false    // No file logging in release
    private let enableConsoleLogging = false // No console output in release
    #endif
    
    private init() {
        // Setup file logging only in debug builds
        #if DEBUG
        if let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let logPath = documentsPath.appendingPathComponent("ViewLingoCam.log")
            self.fileURL = logPath
            
            // Create or clear log file
            if !FileManager.default.fileExists(atPath: logPath.path) {
                FileManager.default.createFile(atPath: logPath.path, contents: nil)
            }
        } else {
            self.fileURL = nil
        }
        #else
        self.fileURL = nil  // No file logging in release
        #endif
        
        dateFormatter.dateFormat = "HH:mm:ss.SSS"
    }
    
    func log(_ level: Level, _ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        // Skip logging if below minimum level
        guard level >= minLogLevel else { return }
        
        let timestamp = dateFormatter.string(from: Date())
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let logMessage = "[\(timestamp)] \(level.rawValue) [\(fileName):\(line)] \(function): \(message)"
        
        // Console logging (only in debug)
        if enableConsoleLogging {
            print(logMessage)
        }
        
        // OS logging (always enabled for system logs, but respects level)
        let osLogType: OSLogType
        switch level {
        case .debug: osLogType = .debug
        case .info: osLogType = .info
        case .warning: osLogType = .default
        case .error: osLogType = .error
        }
        
        // OS log still works in release but only for errors
        os_log("%{public}@", log: osLog, type: osLogType, message)
        
        // File logging (only in debug)
        if enableFileLogging {
            writeToFile(logMessage)
        }
    }
    
    // MARK: - Specialized Logging
    
    func logOnboarding(_ step: String, _ detail: String) {
        log(.info, "📋 [Onboarding] \(step): \(detail)")
    }
    
    func logLanguagePack(_ action: String, _ language: String, _ detail: String) {
        log(.info, "📦 [LanguagePack] \(action) '\(language)': \(detail)")
    }
    
    func logTranslation(source: String?, target: String, success: Bool, texts: Int = 0, error: Error? = nil) {
        let sourceStr = source ?? "auto"
        if success {
            log(.info, "🔤 [Translation] \(sourceStr)→\(target): ✅ Success (\(texts) texts)")
        } else {
            let errorStr = error?.localizedDescription ?? "Unknown error"
            log(.error, "🔤 [Translation] \(sourceStr)→\(target): ❌ Failed - \(errorStr)")
        }
    }
    
    func logOCR(detected: Int, confidence: Double, duration: TimeInterval) {
        log(.info, "👁️ [OCR] Detected \(detected) texts (avg confidence: \(String(format: "%.2f", confidence)), duration: \(String(format: "%.3f", duration))s)")
    }
    
    func logCamera(_ event: String) {
        log(.debug, "📷 [Camera] \(event)")
    }
    
    func logPerformance(fps: Double, memory: Double) {
        log(.debug, "📊 [Performance] FPS: \(String(format: "%.1f", fps)), Memory: \(String(format: "%.1f", memory))MB")
    }
    
    // MARK: - Private Methods
    
    private func writeToFile(_ message: String) {
        guard let fileURL = fileURL else { return }
        
        let messageWithNewline = message + "\n"
        
        if let data = messageWithNewline.data(using: .utf8) {
            if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
            }
        }
    }
    
    // MARK: - Log Management
    
    func clearLog() {
        guard let fileURL = fileURL else { return }
        try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        log(.info, "Log file cleared")
    }
    
    func getLogContents() -> String? {
        guard let fileURL = fileURL else { return nil }
        return try? String(contentsOf: fileURL, encoding: .utf8)
    }
    
    func getLogFileSize() -> Int64 {
        guard let fileURL = fileURL else { return 0 }
        
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let size = attributes[.size] as? Int64 {
            return size
        }
        return 0
    }
}