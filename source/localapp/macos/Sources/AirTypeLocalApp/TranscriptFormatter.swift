import Foundation

/// Turns raw ASR output (Nemotron or Qwen3-ASR) into text for the target app.
/// - removes the spaces Nemotron puts around CJK tokens
/// - uses full-width punctuation after CJK characters
/// - converts Simplified -> Traditional for zh-tw (Nemotron's Mandarin output is Simplified)
/// - rewrites Chinese numerals as Arabic (三十二 -> 32) when the menu toggle is on (see ChineseNumerals)
enum TranscriptFormatter {
    /// `fixEnglishCase`: lowercase ALL-CAPS English words from the sherpa-onnx engines (raw ASR only;
    /// the LLM-polished text keeps whatever casing the LLM chose).
    static func format(_ raw: String, mode: String, fixEnglishCase: Bool = true) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        if fixEnglishCase && lowercaseEnglishEnabled {
            text = lowercaseAllCapsEnglish(text)
        }
        let chinese = ["zh-tw", "zh-cn", "auto-tw", "auto-cn", "auto"].contains(mode)
        if chinese {
            text = normalizeCJKSpacingAndPunctuation(text)
        }
        // Auto modes still let the engine detect zh / en / mixed; only the output script is forced.
        if mode == "zh-tw" || mode == "auto-tw" || mode == "auto" {
            text = toTraditional(text)
        } else if mode == "auto-cn" {
            text = toSimplified(text)
        }
        if ChineseNumerals.enabled {
            text = ChineseNumerals.convert(text)
        }
        return text
    }

    // MARK: - English casing (sherpa-onnx ASR emits HELLO WORLD)

    /// AIRTYPE_EN_LOWERCASE=0 turns it off.
    static var lowercaseEnglishEnabled: Bool {
        ProcessInfo.processInfo.environment["AIRTYPE_EN_LOWERCASE"] != "0"
    }

    /// ASCII words (2+ letters, optional apostrophe parts, not glued to digits/underscores) that are entirely uppercase.
    private static let allCapsWord = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_'])[A-Z]{2,}(?:'[A-Z]+)*(?![A-Za-z0-9_'])"
    )

    /// HELLO -> hello, HELLO WORLD -> hello world, DON'T -> don't. Chinese, mixed-case words (iPhone, OpenAI),
    /// single letters (A 方案, C 語言, I) and letter+digit tokens (GPT4) are left alone.
    static func lowercaseAllCapsEnglish(_ input: String) -> String {
        let ns = input as NSString
        let matches = allCapsWord.matches(in: input, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return input }
        let output = NSMutableString(string: input)
        for match in matches.reversed() {
            output.replaceCharacters(in: match.range, with: ns.substring(with: match.range).lowercased())
        }
        return output as String
    }

    // MARK: - Simplified -> Traditional (Taiwan)

    static let openCCDefaultsKey = "useOpenCC"

    /// OpenCC s2twp (Taiwan phrases: 软件→軟體, 鼠标→滑鼠, 信息→資訊) when the `opencc` CLI is installed
    /// (`brew install opencc`) and enabled; otherwise the macOS character-level Hans-Hant transform.
    static var useOpenCC: Bool {
        if ProcessInfo.processInfo.environment["AIRTYPE_OPENCC"] == "0" { return false }
        return UserDefaults.standard.object(forKey: openCCDefaultsKey) as? Bool ?? true
    }

    static let openCCPath: String? = {
        ["/opt/homebrew/bin/opencc", "/usr/local/bin/opencc"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func toTraditional(_ text: String) -> String {
        if useOpenCC, let converted = openCC(text) {
            return converted
        }
        return text.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false) ?? text
    }

    /// Traditional -> Simplified for "Auto (Simplified)": Qwen3 / Fun-ASR sometimes emit Traditional
    /// characters, so normalise them back. OpenCC tw2sp (mainland phrases) when available, else the macOS transform.
    static func toSimplified(_ text: String) -> String {
        if useOpenCC, let converted = openCC(text, config: "tw2sp.json") {
            return converted
        }
        return text.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? text
    }

    private static func openCC(_ text: String, config: String = "s2twp.json") -> String? {
        guard let path = openCCPath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-c", config]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        input.fileHandleForWriting.write(Data(text.utf8))
        try? input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let result = String(data: data, encoding: .utf8) else { return nil }
        // opencc keeps the input's trailing newline state; we never send one, but trim just in case.
        return result.hasSuffix("\n") && !text.hasSuffix("\n") ? String(result.dropLast()) : result
    }

    private static let fullWidth: [Character: Character] = [
        ",": "，", ".": "。", "?": "？", "!": "！", ":": "：", ";": "；"
    ]

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func normalizeCJKSpacingAndPunctuation(_ input: String) -> String {
        let characters = Array(input)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        for (index, character) in characters.enumerated() {
            if character == " " {
                let previous = output.last
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if previous.map(isCJK) == true || next.map(isCJK) == true || previous == " " {
                    continue
                }
                output.append(character)
                continue
            }
            if let replacement = fullWidth[character], let previous = output.last, isCJK(previous) {
                output.append(replacement)
                continue
            }
            output.append(character)
        }
        return String(output)
    }
}
