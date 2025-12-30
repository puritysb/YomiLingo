//
//  AtomicInt.swift
//  ViewLingo-Cam
//
//  Thread-safe atomic integer for frame counting
//

import Foundation

/// A thread-safe atomic integer wrapper
final class AtomicInt: @unchecked Sendable {
    private var value: Int = 0
    private let lock = NSLock()
    
    /// Initialize with a default value
    init(value: Int = 0) {
        self.value = value
    }
    
    /// Increment the value and return the new value
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
    
    /// Get the current value
    func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    
    /// Set a new value
    func set(_ newValue: Int) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
    
    /// Reset to zero
    func reset() {
        set(0)
    }
}