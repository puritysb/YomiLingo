//
//  TextRecovery.swift
//  ViewLingo-Cam
//
//  OCR Text Recovery and Cleaning System
//

import Foundation

/// Utility class for recovering and cleaning OCR text with errors
class TextRecovery {
    
    // MARK: - Common OCR Misrecognition Patterns
    
    /// Common character substitutions for OCR errors
    private static let characterSubstitutions: [String: String] = [
        "￿": "",        // Remove replacement character
        "•": "",        // Remove bullets in middle of words
        "·": "",        // Remove middle dots
        "l": "I",       // Lowercase L often misread
        "0": "O",       // Zero vs O confusion
        "rn": "m",      // rn looks like m
        "cl": "d",      // cl looks like d
        "vv": "w",      // vv looks like w
        "VV": "W",      // VV looks like W
        "ii": "n",      // ii can look like n
        "IJ": "U",      // IJ can look like U
        "lJ": "U",      // lJ combination
        "Il": "U",      // Il combination
        "l)": "b",      // l) can look like b
        "I)": "D",      // I) can look like D
        "][": "I",      // ][ can be I
        "()": "O",      // () can be O
        "GI": "Gl",     // GIow → Glow
        "lI": "ll",     // Lowercase l and uppercase I confusion
        "aI": "al",     // haraIe → harale
    ]
    
    /// Japanese-specific OCR corrections
    private static let japaneseCorrections: [String: String] = [
        // Common katakana misrecognitions
        "ソ": "ン",      // ソ often misread as ン
        "シ": "ツ",      // シ and ツ confusion
        "ン": "ソ",      // Reverse mapping
        "ツ": "シ",      // Reverse mapping
        "ロ": "口",      // Katakana ロ vs Kanji 口
        "エ": "工",      // Katakana エ vs Kanji 工
        "カ": "力",      // Katakana カ vs Kanji 力
        "ニ": "二",      // Katakana ニ vs Kanji 二
        "ー": "一",      // Long vowel mark vs Kanji one
        
        // Common hiragana misrecognitions  
        "ぬ": "ね",      // Similar shapes
        "れ": "ね",      // Similar shapes
        "わ": "ね",      // Similar shapes
        "め": "ぬ",      // Similar shapes
        "る": "ろ",      // Similar shapes
        "は": "ほ",      // Similar shapes when small
        "ま": "よ",      // Similar shapes
        
        // Dakuten/Handakuten issues
        "は゛": "ば",    // Separated dakuten
        "は゜": "ぱ",    // Separated handakuten
        "か゛": "が",    // Separated dakuten
        "き゛": "ぎ",    // Separated dakuten
        "く゛": "ぐ",    // Separated dakuten
        "け゛": "げ",    // Separated dakuten
        "こ゛": "ご",    // Separated dakuten
    ]
    
    /// Korean-specific OCR corrections
    private static let koreanCorrections: [String: String] = [
        // Common Hangul misrecognitions
        "ㅁ": "ㅇ",      // ㅁ misread as ㅇ
        "ㅂ": "ㅍ",      // ㅂ misread as ㅍ
        "ㅈ": "ㅊ",      // ㅈ misread as ㅊ
        "ㄷ": "ㄹ",      // ㄷ misread as ㄹ
        "ㅏ": "ㅑ",      // ㅏ misread as ㅑ
        "ㅓ": "ㅕ",      // ㅓ misread as ㅕ
        "ㅗ": "ㅛ",      // ㅗ misread as ㅛ
        "ㅜ": "ㅠ",      // ㅜ misread as ㅠ
        
        // Common syllable misrecognitions
        "대": "데",      // Similar shapes
        "배": "베",      // Similar shapes
        "개": "게",      // Similar shapes
        "내": "네",      // Similar shapes
        "매": "메",      // Similar shapes
    ]
    
    /// Korean-Japanese cross-language misrecognition patterns
    private static let koreanJapaneseMisrecognitions: [String: String] = [
        // Korean misread as Japanese
        "가": "か",      // Korean 가 misread as Japanese か
        "나": "な",      // Korean 나 misread as Japanese な
        "다": "た",      // Korean 다 misread as Japanese た
        "라": "ら",      // Korean 라 misread as Japanese ら
        "마": "ま",      // Korean 마 misread as Japanese ま
        "사": "さ",      // Korean 사 misread as Japanese さ
        "아": "あ",      // Korean 아 misread as Japanese あ
        "자": "じゃ",    // Korean 자 misread as Japanese じゃ
        "하": "は",      // Korean 하 misread as Japanese は
        
        // Japanese misread as Korean  
        "の": "ㅇ",      // Japanese の misread as Korean ㅇ
        "て": "ㄷ",      // Japanese て misread as Korean ㄷ
        "と": "ㅌ",      // Japanese と misread as Korean ㅌ
        "も": "ㅁ",      // Japanese も misread as Korean ㅁ
        "ス": "스",      // Japanese ス misread as Korean 스
        "ト": "트",      // Japanese ト misread as Korean 트
        "ロ": "로",      // Japanese ロ misread as Korean 로
        "リ": "리",      // Japanese リ misread as Korean 리
    ]
    
    /// Pattern-based replacements (regex)
    private static let patternReplacements: [(pattern: String, replacement: String)] = [
        ("￿+", ""),                           // Remove all replacement chars
        ("[•·]{2,}", ""),                     // Remove consecutive bullets/dots
        ("([a-zA-Z])[•·]([a-zA-Z])", "$1$2"), // Remove single bullet between letters
        ("\\s{2,}", " "),                     // Collapse multiple spaces
        ("^[•·\\s]+|[•·\\s]+$", ""),         // Trim bullets/spaces from ends
    ]
    
    /// Common English words that are often misrecognized
    private static let commonEnglishCorrections: [String: String] = [
        "GIow": "Glow",
        "haraIe": "harale",
        "cIean": "clean",
        "cIear": "clear",
        "beautifuI": "beautiful",
        "naturaI": "natural",
        "speciaI": "special",
        "originaI": "original",
        "finaI": "final",
        "totaI": "total",
        "IocaI": "local",
        "gIobaI": "global",
        "normaI": "normal",
        "reaI": "real",
        "ideaI": "ideal",
    ]
    
    // MARK: - Text Cleaning Methods
    
    /// Clean OCR text by removing/replacing problematic characters
    static func cleanText(_ text: String) -> String? {
        var cleaned = text
        
        // Step 1: Remove replacement characters and obvious noise
        cleaned = cleaned.replacingOccurrences(of: "￿", with: "")
        
        // Step 2: Apply character substitutions
        for (from, to) in characterSubstitutions {
            cleaned = cleaned.replacingOccurrences(of: from, with: to)
        }
        
        // Step 3: Apply pattern-based replacements
        for (pattern, replacement) in patternReplacements {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(location: 0, length: cleaned.utf16.count)
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    range: range,
                    withTemplate: replacement
                )
            }
        }
        
        // Step 4: Trim whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Return nil if cleaned text is too short or empty
        return cleaned.count >= 2 ? cleaned : nil
    }
    
    /// Attempt to recover text with special characters
    static func recoverText(_ text: String) -> String? {
        // Check if text contains Japanese/CJK characters
        let hasJapanese = text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}]", options: .regularExpression) != nil
        let hasKorean = text.range(of: "[\u{ac00}-\u{d7a3}\u{3131}-\u{318e}]", options: .regularExpression) != nil
        let hasCJK = hasJapanese || hasKorean
        
        // Apply language-specific corrections
        var processedText = text
        if hasJapanese {
            processedText = applyJapaneseCorrections(processedText)
        }
        if hasKorean {
            processedText = applyKoreanCorrections(processedText)
        }
        
        // Apply cross-language corrections for mixed/misrecognized text
        if hasJapanese && hasKorean {
            processedText = applyCrossLanguageCorrections(processedText)
        }
        
        // Apply English corrections if no CJK characters
        if !hasCJK {
            processedText = applyEnglishCorrections(processedText)
        }
        
        // First try basic cleaning
        if let cleaned = cleanText(processedText) {
            // Check if cleaned text is valid
            if isRecoveredTextValid(cleaned, isCJK: hasCJK) {
                return cleaned
            }
        }
        
        // Try more aggressive recovery for specific patterns
        var recovered = processedText
        
        // Handle "JUbl" → "JUNG" type corrections (skip for CJK)
        if !hasCJK {
            recovered = applyContextualCorrections(recovered)
        }
        
        // For CJK text, be more careful with character removal
        if hasCJK {
            // Only remove obvious noise, keep CJK characters and punctuation
            recovered = recovered.replacingOccurrences(of: "￿", with: "")
            recovered = recovered.replacingOccurrences(of: "[•·]{2,}", with: "", options: .regularExpression)
        } else {
            // For non-CJK, remove all special characters except spaces and common punctuation
            let allowedChars = CharacterSet.alphanumerics.union(.whitespaces).union(.init(charactersIn: ",.!?-'\""))
            recovered = String(recovered.unicodeScalars.filter { allowedChars.contains($0) })
        }
        
        // Final cleaning
        recovered = recovered.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // CJK text can be valid with just 1 character
        let minLength = hasCJK ? 1 : 2
        return recovered.count >= minLength ? recovered : nil
    }
    
    /// Apply contextual corrections based on common patterns
    private static func applyContextualCorrections(_ text: String) -> String {
        var corrected = text
        
        // Common word corrections
        let wordCorrections = [
            "JUbl": "JUNG",
            "Jubl": "Jung",
            "FIAU": "FRAU",
            "FlAU": "FRAU",
            "lN": "IN",
            "0F": "OF",
            "T0": "TO",
            "FR0M": "FROM",
            "THlS": "THIS",
            "WlTH": "WITH",
            "Y0U": "YOU"
        ]
        
        for (from, to) in wordCorrections {
            corrected = corrected.replacingOccurrences(of: from, with: to)
        }
        
        return corrected
    }
    
    /// Apply Japanese-specific corrections
    private static func applyJapaneseCorrections(_ text: String) -> String {
        var corrected = text
        
        // Apply Japanese-specific character corrections
        for (from, to) in japaneseCorrections {
            corrected = corrected.replacingOccurrences(of: from, with: to)
        }
        
        // Fix separated dakuten/handakuten marks
        let dakutenPattern = "([かきくけこさしすせそたちつてとはひふへほ])\\s*゛"
        if let regex = try? NSRegularExpression(pattern: dakutenPattern) {
            let range = NSRange(location: 0, length: corrected.utf16.count)
            corrected = regex.stringByReplacingMatches(
                in: corrected,
                range: range,
                withTemplate: "$1゛"  // Rejoin separated dakuten
            )
        }
        
        // Fix common Japanese word patterns
        let japaneseWordCorrections = [
            "で　す": "です",
            "ま　す": "ます",
            "し　た": "した",
            "あ　る": "ある",
            "い　る": "いる",
            "な　い": "ない",
            "て　い": "てい",
            "こ　と": "こと",
            "も　の": "もの",
        ]
        
        for (from, to) in japaneseWordCorrections {
            corrected = corrected.replacingOccurrences(of: from, with: to)
        }
        
        return corrected
    }
    
    /// Check if recovered text is valid
    private static func isRecoveredTextValid(_ text: String, isCJK: Bool = false) -> Bool {
        if isCJK {
            // For CJK text, just check it has at least one CJK character
            let hasCJKChar = text.range(of: "[\u{3040}-\u{309f}\u{30a0}-\u{30ff}\u{4e00}-\u{9faf}\u{ac00}-\u{d7a3}]", 
                                        options: .regularExpression) != nil
            return hasCJKChar && text.count >= 1
        }
        
        // Must have at least one letter for non-CJK
        guard text.range(of: "[a-zA-Z]", options: .regularExpression) != nil else {
            return false
        }
        
        // Should not be all uppercase single letters separated by spaces
        let components = text.split(separator: " ")
        if components.count > 2 && components.allSatisfy({ $0.count == 1 }) {
            return false
        }
        
        // Check letter to non-letter ratio
        let letters = text.filter { $0.isLetter }.count
        let total = text.filter { !$0.isWhitespace }.count
        
        return total > 0 && (Double(letters) / Double(total)) >= 0.5
    }
    
    // MARK: - Multi-Candidate Fusion
    
    /// Merge multiple OCR candidates to get best result
    static func fuseCandidates(_ candidates: [(text: String, confidence: Float)]) -> String? {
        guard !candidates.isEmpty else { return nil }
        
        // If only one candidate, try to clean it
        if candidates.count == 1 {
            return recoverText(candidates[0].text)
        }
        
        // Clean all candidates first
        let cleanedCandidates = candidates.compactMap { candidate -> (String, Float)? in
            guard let cleaned = cleanText(candidate.text) else { return nil }
            return (cleaned, candidate.confidence)
        }
        
        guard !cleanedCandidates.isEmpty else {
            // If all cleaning failed, try recovery on best confidence
            let best = candidates.max(by: { $0.confidence < $1.confidence })
            return best.flatMap { recoverText($0.text) }
        }
        
        // If all cleaned texts are similar, return the highest confidence one
        if areTextsSimilar(cleanedCandidates.map { $0.0 }) {
            return cleanedCandidates.max(by: { $0.1 < $1.1 })?.0
        }
        
        // Otherwise, try character-level voting
        return characterLevelVoting(cleanedCandidates)
    }
    
    /// Check if texts are similar enough to be considered the same
    private static func areTextsSimilar(_ texts: [String], threshold: Double = 0.8) -> Bool {
        guard texts.count > 1 else { return true }
        
        for i in 0..<texts.count {
            for j in (i+1)..<texts.count {
                let similarity = textSimilarity(texts[i], texts[j])
                if similarity < threshold {
                    return false
                }
            }
        }
        return true
    }
    
    /// Calculate text similarity (0-1)
    private static func textSimilarity(_ text1: String, _ text2: String) -> Double {
        let longer = text1.count > text2.count ? text1 : text2
        let shorter = text1.count > text2.count ? text2 : text1
        
        guard longer.count > 0 else { return 1.0 }
        
        let editDistance = levenshteinDistance(shorter, longer)
        return 1.0 - (Double(editDistance) / Double(longer.count))
    }
    
    /// Calculate Levenshtein distance between two strings
    private static func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let m = s1.count
        let n = s2.count
        
        if m == 0 { return n }
        if n == 0 { return m }
        
        var matrix = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        
        for i in 1...m { matrix[i][0] = i }
        for j in 1...n { matrix[0][j] = j }
        
        for i in 1...m {
            for j in 1...n {
                let cost = (Array(s1)[i-1] == Array(s2)[j-1]) ? 0 : 1
                matrix[i][j] = min(
                    matrix[i-1][j] + 1,     // deletion
                    matrix[i][j-1] + 1,     // insertion
                    matrix[i-1][j-1] + cost // substitution
                )
            }
        }
        
        return matrix[m][n]
    }
    
    /// Perform character-level voting to get best text
    private static func characterLevelVoting(_ candidates: [(String, Float)]) -> String {
        guard !candidates.isEmpty else { return "" }
        
        // Find the maximum length
        let maxLength = candidates.map { $0.0.count }.max() ?? 0
        var result = ""
        
        for position in 0..<maxLength {
            var charVotes: [Character: Float] = [:]
            
            for (text, confidence) in candidates {
                let chars = Array(text)
                if position < chars.count {
                    let char = chars[position]
                    charVotes[char, default: 0] += confidence
                }
            }
            
            // Select character with highest weighted vote
            if let bestChar = charVotes.max(by: { $0.value < $1.value })?.key {
                result.append(bestChar)
            }
        }
        
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Temporal Fusion
    
    /// Accumulate and fuse text over multiple frames
    class TemporalAccumulator {
        private var observations: [(text: String, confidence: Float, timestamp: Date)] = []
        private let maxObservations = 5
        private let timeWindow: TimeInterval = 1.0 // 1 second window
        
        /// Add new observation
        func addObservation(_ text: String, confidence: Float) {
            let now = Date()
            
            // Remove old observations outside time window
            observations = observations.filter { now.timeIntervalSince($0.timestamp) < timeWindow }
            
            // Add new observation
            observations.append((text, confidence, now))
            
            // Keep only most recent observations
            if observations.count > maxObservations {
                observations = Array(observations.suffix(maxObservations))
            }
        }
        
        /// Get best fused text from accumulated observations
        func getBestText() -> String? {
            guard !observations.isEmpty else { return nil }
            
            let candidates = observations.map { ($0.text, $0.confidence) }
            return TextRecovery.fuseCandidates(candidates)
        }
        
        /// Clear all observations
        func clear() {
            observations.removeAll()
        }
    }
    
    /// Apply Korean-specific corrections
    private static func applyKoreanCorrections(_ text: String) -> String {
        var corrected = text
        
        // Apply Korean corrections
        for (from, to) in koreanCorrections {
            corrected = corrected.replacingOccurrences(of: from, with: to)
        }
        
        // Fix common Korean word patterns
        let koreanWordCorrections = [
            "습 니 다": "습니다",
            "입 니 다": "입니다",
            "있 습 니 다": "있습니다",
            "없 습 니 다": "없습니다",
            "합 니 다": "합니다",
            "됩 니 다": "됩니다",
            "했 습 니 다": "했습니다",
            "이 에 요": "이에요",
            "예 요": "예요",
            "어 요": "어요",
        ]
        
        for (from, to) in koreanWordCorrections {
            corrected = corrected.replacingOccurrences(of: from, with: to)
        }
        
        return corrected
    }
    
    /// Apply cross-language corrections for misrecognized Korean/Japanese text
    private static func applyCrossLanguageCorrections(_ text: String) -> String {
        var corrected = text
        
        // Check character distribution to determine dominant language
        let koreanCount = text.filter { char in
            let scalar = char.unicodeScalars.first?.value ?? 0
            return (scalar >= 0xAC00 && scalar <= 0xD7A3) ||
                   (scalar >= 0x3131 && scalar <= 0x318E)
        }.count
        
        let japaneseCount = text.filter { char in
            let scalar = char.unicodeScalars.first?.value ?? 0
            return (scalar >= 0x3040 && scalar <= 0x309F) ||
                   (scalar >= 0x30A0 && scalar <= 0x30FF)
        }.count
        
        // Apply corrections based on dominant language
        if koreanCount > japaneseCount {
            // More Korean - correct Japanese characters that should be Korean
            // Iterate through misrecognitions where Japanese was misread as Korean
            for (japanese, korean) in koreanJapaneseMisrecognitions {
                // If we have more Korean, replace any stray Japanese with Korean
                if japanese.first?.unicodeScalars.first?.value ?? 0 < 0xAC00 {
                    // This is a Japanese character that might be misread
                    corrected = corrected.replacingOccurrences(of: japanese, with: korean)
                }
            }
        } else {
            // More Japanese - correct Korean characters that should be Japanese  
            for (japanese, korean) in koreanJapaneseMisrecognitions {
                // If we have more Japanese, replace any stray Korean with Japanese
                if korean.first?.unicodeScalars.first?.value ?? 0 >= 0xAC00 {
                    // This is a Korean character that might be misread
                    corrected = corrected.replacingOccurrences(of: korean, with: japanese)
                }
            }
        }
        
        return corrected
    }
    
    /// Apply English-specific corrections for common OCR errors
    private static func applyEnglishCorrections(_ text: String) -> String {
        var corrected = text
        
        // First apply common word corrections
        for (from, to) in commonEnglishCorrections {
            corrected = corrected.replacingOccurrences(of: from, with: to, options: .caseInsensitive)
        }
        
        // Apply pattern-based corrections for I/l confusion
        // Replace uppercase I with lowercase l in middle of words
        let pattern = "([a-z])I([a-z])"
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let range = NSRange(location: 0, length: corrected.utf16.count)
            corrected = regex.stringByReplacingMatches(
                in: corrected,
                range: range,
                withTemplate: "$1l$2"
            )
        }
        
        return corrected
    }
}

// MARK: - Extensions

extension String {
    /// Check if string contains broken OCR characters
    var hasOCRErrors: Bool {
        return self.contains("￿") || 
               self.range(of: "[•·]{2,}", options: .regularExpression) != nil
    }
    
    /// Quick OCR recovery attempt
    var ocrRecovered: String? {
        return TextRecovery.recoverText(self)
    }
}

extension Character {
    /// Check if character is Korean
    var isKorean: Bool {
        guard let scalar = self.unicodeScalars.first?.value else { return false }
        return (scalar >= 0xAC00 && scalar <= 0xD7A3) ||  // Hangul syllables
               (scalar >= 0x3131 && scalar <= 0x318E) ||  // Hangul compatibility
               (scalar >= 0x1100 && scalar <= 0x11FF)      // Hangul Jamo
    }
    
    /// Check if character is Japanese kana
    var isJapaneseKana: Bool {
        guard let scalar = self.unicodeScalars.first?.value else { return false }
        return (scalar >= 0x3040 && scalar <= 0x309F) ||  // Hiragana
               (scalar >= 0x30A0 && scalar <= 0x30FF)      // Katakana
    }
}