# ViewLingo Cam Testing Guide

## 🎯 Test Scenarios

### 1. Korean Target (ko) - Should Translate English/Japanese

**Test Text (English):**
```
Hello World
This is a test
Translation App
```

**Test Text (Japanese):**
```
こんにちは
テストです
翻訳アプリ
```

**Expected Behavior:**
- English text → Korean translation appears
- Japanese text → Korean translation appears
- Korean text → NO translation (same language)

### 2. English Target (en) - Should Translate Korean/Japanese

**Test Text (Korean):**
```
안녕하세요
테스트입니다
번역 앱
```

**Test Text (Japanese):**
```
こんにちは
テストです
翻訳アプリ
```

**Expected Behavior:**
- Korean text → English translation appears
- Japanese text → English translation appears
- English text → NO translation (same language)

### 3. Japanese Target (ja) - Should Translate Korean/English

**Test Text (Korean):**
```
안녕하세요
테스트입니다
번역 앱
```

**Test Text (English):**
```
Hello World
This is a test
Translation App
```

**Expected Behavior:**
- Korean text → Japanese translation appears
- English text → Japanese translation appears
- Japanese text → NO translation (same language)

## 🔍 Debugging Steps

### 1. Check Debug Overlay
- Tap the bug icon in top-right corner
- Verify OCR detected texts count
- Check language detection results
- Monitor translation time

### 2. Check Console Logs
Look for these key log messages:

**Successful Translation Flow:**
```
Processing X texts for translation to [target]
Text 'xxx...' detected as: [language]
Language detection summary:
  - Total texts: X
  - Skipped (same language): Y
  - To translate: Z
  - Languages found: en, ja
Available sessions: en→ko, ja→ko
Using session en→ko to translate X texts
✅ Successfully translated X texts
```

**Common Issues:**
```
"No texts require translation" - All texts detected as target language
"No session for language pair" - Missing translation session
"Translation not available" - Language packs not installed
```

### 3. Performance Monitoring
- Live Mode: Should use Fast OCR mode
- Manual Capture: Should use Accurate OCR mode
- Frame skipping: Every 3rd frame in Live mode
- OCR time: Should be < 500ms in Fast mode

## 📱 Test on Device

### Setup Test Images:
1. Create simple test cards with text in different languages
2. Use clear, high-contrast text
3. Good lighting conditions
4. Hold camera steady

### Test Flow:
1. **Onboarding**: Select target language (e.g., Korean)
2. **Camera Mode**: Point at English text
3. **Manual Capture**: Tap capture button
4. **Check Debug**: Verify detection and translation
5. **Live Mode**: Toggle live mode and move camera slowly
6. **Language Switch**: Change target language and verify sessions update

## 🐛 Known Issues & Solutions

### Issue: "No texts require translation"
**Cause**: All texts detected as same language as target
**Solution**: 
- Check language detection confidence thresholds
- Test with clearer, longer text
- Verify language detection is working correctly

### Issue: OCR takes too long (>1 second)
**Cause**: Using Accurate mode or main thread blocking
**Solution**: 
- Switch to Fast mode for Live
- Verify background queue processing
- Check frame skipping is working

### Issue: No translation appears
**Cause**: Missing translation session or language pack
**Solution**:
- Check console for "Available sessions" log
- Verify language packs installed in onboarding
- Check session creation in CameraView

## 📊 Success Criteria

✅ **English → Korean translation works**
✅ **Japanese → Korean translation works**
✅ **Korean text is NOT translated when target is Korean**
✅ **Live mode processes smoothly (<500ms per frame)**
✅ **No popups appear in camera mode**
✅ **Debug overlay shows correct stats**

---
**Last Updated**: 2025-01-28
**Version**: 2.0