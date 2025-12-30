//
//  UnsafeSendable.swift
//  ViewLingo-Cam
//
//  Wrapper for non-Sendable types that are known to be thread-safe
//

import Foundation

/// A wrapper that marks a value as Sendable without compiler checks.
/// Use this ONLY for types that are genuinely thread-safe but don't conform to Sendable.
/// 
/// CVPixelBuffer is thread-safe internally but doesn't conform to Sendable in Swift 6.
struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    
    init(_ value: T) {
        self.value = value
    }
}