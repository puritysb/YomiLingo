//
//  CIContextHelper.swift
//  ViewLingo-Cam
//
//  Helper for creating iPad-compatible CIContext instances
//

import CoreImage
import Metal

/// Shared CIContext helper for iPad compatibility
struct CIContextHelper {
    
    /// Shared CIContext instance for better performance
    static let shared: CIContext = {
        // Create CIContext with Metal and shared storage mode for iPad compatibility
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            // Use Metal with proper options to fix iPad crash
            return CIContext(mtlDevice: metalDevice, options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
                .useSoftwareRenderer: false,
                .cacheIntermediates: true,  // Cache for better performance
                .name: "ViewLingo-CIContext"
            ])
        } else {
            // Fallback to CPU renderer if Metal is not available
            return CIContext(options: [
                .useSoftwareRenderer: true,
                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                .outputColorSpace: CGColorSpaceCreateDeviceRGB()
            ])
        }
    }()
    
    /// Create a new CIContext with iPad-compatible settings
    /// Use this when you need a separate context (rare cases)
    static func createContext() -> CIContext {
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: metalDevice, options: [
                .workingColorSpace: CGColorSpaceCreateDeviceRGB(),
                .outputColorSpace: CGColorSpaceCreateDeviceRGB(),
                .useSoftwareRenderer: false
            ])
        } else {
            return CIContext(options: [.useSoftwareRenderer: true])
        }
    }
}