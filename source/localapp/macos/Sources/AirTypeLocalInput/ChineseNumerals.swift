import Foundation

/// Rewrites Chinese numerals in ASR output as Arabic numerals before preview / typing / paste:
///   三十二 -> 32, 二零二六年十月三十一日 -> 2026年10月31日, 兩百五 -> 250, 三萬五千 -> 35000, 三百萬 -> 300萬,
///   零九一二三四五六七八 -> 0912345678, 三點五 -> 3.5, 百分之三十 -> 30%, 三分之一 -> 1/3, 第三章 -> 第3章.
/// Deliberately conservative with words that only look numeric: 一起 / 一樣 / 一點 / 十分 / 千萬 / 萬一 / 星期一 /
/// 三四個 (approximate) / 一五一十 stay Chinese. A lone 一 is only converted before date/time/measure units
/// (一月, 一點半, 一小時, 一公里, 第一), so 一個 / 一次 / 一天 keep reading naturally.
enum ChineseNumerals {
    static let defaultsKey = "arabicNumerals"

    /// Menu toggle (default on). AIRTYPE_ARABIC_NUMERALS=0 forces it off.
    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["AIRTYPE_ARABIC_NUMERALS"] == "0" { return false }
        return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    private static let digits: [Character: Int] = [
        "零": 0, "〇": 0, "○": 0, "一": 1, "幺": 1, "二": 2, "兩": 2, "两": 2,
        "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let smallUnits: [Character: Int] = ["十": 10, "百": 100, "千": 1000]
    private static let bigUnits: [Character: Int] = ["萬": 10_000, "万": 10_000, "億": 100_000_000, "亿": 100_000_000]
    private static let twoForms: Set<Character> = ["兩", "两"]
    private static let pointChars: Set<Character> = ["點", "点"]

    /// Units after which even a lone 一 becomes 1 (dates, clock time, measurements).
    private static let strongUnits = [
        "月", "日", "號", "号", "歲", "岁", "小時", "小时", "分鐘", "分钟", "秒", "公里", "公尺", "公分", "公斤",
        "公克", "公升", "毫升", "毫秒", "釐米", "厘米", "毫米", "米", "%", "％", "度", "樓", "楼", "點半", "点半",
        "點鐘", "点钟", "週年", "周年", "年級", "年级", "成", "折",
    ]
    /// Counting units: convert 二..九 / 兩 / 十 (but not a lone 一) before these.
    private static let countUnits = [
        "年", "天", "週", "周", "星期", "禮拜", "礼拜", "個", "个", "次", "人", "位", "名", "件", "項", "项", "條", "条",
        "張", "张", "台", "臺", "本", "頁", "页", "章", "節", "节", "篇", "種", "种", "份", "支", "顆", "颗", "隻", "只",
        "元", "塊", "块", "倍", "分", "行", "列", "層", "层", "字", "版", "季", "輪", "轮", "場", "场", "題", "题",
        "票", "筆", "笔", "家", "間", "间", "座", "台", "部", "集", "期", "組", "组", "套", "歲", "代", "核", "顆",
        "萬", "万", "億", "亿", "千", "百", "點", "点",
    ]

    static func convert(_ text: String) -> String {
        let chars = Array(text)
        guard chars.contains(where: { isNumeral($0) }) else { return text }
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            // 百分之三十 -> 30%
            if has(chars, "百分之", at: i), let (num, end) = readNumber(chars, at: i + 3) {
                out.append(contentsOf: num + "%")
                i = end
                continue
            }
            guard isNumeral(chars[i]) else {
                out.append(chars[i])
                i += 1
                continue
            }
            // A run cannot start with 百 / 千 / 萬 / 億 (千萬, 萬一, 百般 stay as words).
            if smallUnits[chars[i]] ?? 0 >= 100 || bigUnits[chars[i]] != nil {
                out.append(chars[i])
                i += 1
                continue
            }
            var end = i
            while end < chars.count, isNumeral(chars[end]) { end += 1 }
            let run = Array(chars[i..<end])

            // 三分之一 -> 1/3
            if has(chars, "分之", at: end), let denominator = forced(run),
               let (numerator, fracEnd) = readNumber(chars, at: end + 2) {
                out.append(contentsOf: "\(numerator)/\(denominator)")
                i = fracEnd
                continue
            }

            guard let converted = contextual(run, before: out, chars: chars, after: end) else {
                out.append(contentsOf: run)
                i = end
                continue
            }
            out.append(contentsOf: converted)
            i = end
            // 三點五 -> 3.5 (but 三點五十分 / 三點半 stay clock time)
            if let (fraction, fracEnd) = decimalPart(chars, at: end) {
                out.append(contentsOf: "." + fraction)
                i = fracEnd
            }
        }
        return String(out)
    }

    // MARK: - Context rules

    private static func contextual(_ run: [Character], before: [Character], chars: [Character], after end: Int) -> String? {
        let pureDigits = run.allSatisfy { digits[$0] != nil }
        if run.count == 1 || run == ["十"] {
            return single(run[0], before: before, chars: chars, after: end)
        }
        if pureDigits {
            // 三四個 / 五六天 / 一兩 / 兩三 are approximations, not 34 / 56; keep two-character digit strings.
            if run.count == 2 || run.contains(where: { twoForms.contains($0) }) { return nil }
            return run.map { String(digits[$0]!) }.joined()   // 二零二六 -> 2026, 零九一二... -> 0912...
        }
        return positional(run)   // 三十二 -> 32; nil for 一五一十, 三四十, 九九八十一
    }

    private static func single(_ c: Character, before: [Character], chars: [Character], after end: Int) -> String? {
        let value = c == "十" ? 10 : digits[c]!
        let tail = String(before.suffix(2))
        if tail.hasSuffix("星期") || tail.hasSuffix("禮拜") || tail.hasSuffix("礼拜")
            || before.last == "週" || before.last == "周" {
            return nil   // 星期一 / 週三 stay Chinese
        }
        if decimalPart(chars, at: end) != nil { return String(value) }   // 零點五 / 三點五
        if c == "零" || c == "〇" || c == "○" || c == "幺" { return nil }
        if before.last == "第" { return String(value) }   // 第三章 -> 第3章
        if strongUnits.contains(where: { has(chars, $0, at: end) }) { return String(value) }
        if pointChars.contains(at(chars, end)), digits[at(chars, end + 1)] != nil || smallUnits[at(chars, end + 1)] == 10 {
            return String(value)   // 三點十分 -> 3點10分
        }
        if c == "一" { return nil }   // 一個 / 一次 / 一天 / 一起 / 一點 stay words
        if c == "十", has(chars, "分", at: end) { return nil }   // 十分 (= very); 十分鐘 handled above
        if countUnits.contains(where: { has(chars, $0, at: end) }) { return String(value) }
        if at(chars, end).isASCII, at(chars, end).isLetter { return String(value) }   // 兩GB, 三PR
        return nil
    }

    /// Converts regardless of context (used after 百分之 / 分之). Two-character digit strings are joined (三五 -> 35).
    private static func forced(_ run: [Character]) -> String? {
        if run.allSatisfy({ digits[$0] != nil }) {
            if run.count > 1, run.contains(where: { twoForms.contains($0) }) { return nil }
            return run.map { String(digits[$0]!) }.joined()
        }
        return positional(run)
    }

    private static func readNumber(_ chars: [Character], at start: Int) -> (String, Int)? {
        guard start < chars.count, isNumeral(chars[start]), bigUnits[chars[start]] == nil,
              (smallUnits[chars[start]] ?? 10) == 10 else { return nil }
        var end = start
        while end < chars.count, isNumeral(chars[end]) { end += 1 }
        guard let value = forced(Array(chars[start..<end])) else { return nil }
        if let (fraction, fracEnd) = decimalPart(chars, at: end) {
            return (value + "." + fraction, fracEnd)
        }
        return (value, end)
    }

    /// 點 + plain digits not followed by 分/鐘 -> decimal digits.
    private static func decimalPart(_ chars: [Character], at index: Int) -> (String, Int)? {
        guard pointChars.contains(at(chars, index)) else { return nil }
        var end = index + 1
        while end < chars.count, let _ = digits[chars[end]], !twoForms.contains(chars[end]) { end += 1 }
        guard end > index + 1 else { return nil }
        if isNumeral(at(chars, end)) { return nil }   // 三點五十 -> clock time, not 3.5十
        let next = at(chars, end)
        if next == "分" || next == "鐘" || next == "钟" || next == "刻" { return nil }
        return (chars[(index + 1)..<end].map { String(digits[$0]!) }.joined(), end)
    }

    /// Strict positional parse: 十五, 三十二, 一百零五, 兩千零二十六, 三萬五千, 兩百五 (=250), 一萬五 (=15000).
    private static func positional(_ run: [Character]) -> String? {
        var total = 0, section = 0
        var current: Int? = nil
        var lastUnit = Int.max, lastBig = Int.max
        var zeroSinceUnit = false
        var bigChar: Character? = nil
        for (index, c) in run.enumerated() {
            if let d = digits[c] {
                if current != nil { return nil }            // 三十五六, 一五一十
                if d == 0 {
                    if zeroSinceUnit || (lastUnit == Int.max && lastBig == Int.max) { return nil }
                    zeroSinceUnit = true
                    continue
                }
                if twoForms.contains(c), index + 1 >= run.count || digits[run[index + 1]] != nil {
                    // trailing 兩 (一百兩) is unusual; still a 2
                }
                current = d
            } else if let u = smallUnits[c] {
                if u >= lastUnit { return nil }
                let n: Int
                if let current { n = current } else if u == 10, index == 0 || zeroSinceUnit || lastUnit == Int.max {
                    n = 1                                    // 十五, 一百零十 -> treat 十 as 一十
                } else { return nil }
                section += n * u
                current = nil
                lastUnit = u
                zeroSinceUnit = false
            } else if let b = bigUnits[c] {
                if b >= lastBig { return nil }
                section += current ?? 0
                current = nil
                if section == 0 { return nil }
                total += section * b
                section = 0
                lastUnit = Int.max
                lastBig = b
                zeroSinceUnit = false
                bigChar = c
            } else {
                return nil
            }
        }
        if let current {
            if !zeroSinceUnit, lastUnit != Int.max, lastUnit >= 100 {
                section += current * lastUnit / 10           // 兩百五 -> 250, 三千五 -> 3500
            } else if !zeroSinceUnit, lastUnit == Int.max, lastBig != Int.max {
                section += current * lastBig / 10            // 一萬五 -> 15000
            } else {
                section += current
            }
        }
        let value = total + section
        if value == 0 { return nil }
        // Keep 萬 / 億 for round amounts: 三百萬 -> 300萬, 五億 -> 5億, 三億五千萬 -> 3億5000萬.
        if let bigChar, value % 10_000 == 0 {
            let yi: Character = bigChar == "亿" || bigChar == "万" ? "亿" : "億"
            let wan: Character = bigChar == "亿" || bigChar == "万" ? "万" : "萬"
            let hi = value / 100_000_000, lo = (value % 100_000_000) / 10_000
            return (hi > 0 ? "\(hi)\(yi)" : "") + (lo > 0 ? "\(lo)\(wan)" : "")
        }
        return String(value)
    }

    // MARK: - Helpers

    private static func isNumeral(_ c: Character) -> Bool {
        digits[c] != nil || smallUnits[c] != nil || bigUnits[c] != nil
    }

    private static func at(_ chars: [Character], _ index: Int) -> Character {
        index >= 0 && index < chars.count ? chars[index] : "\u{0}"
    }

    private static func has(_ chars: [Character], _ word: String, at index: Int) -> Bool {
        let w = Array(word)
        guard index >= 0, index + w.count <= chars.count else { return false }
        return Array(chars[index..<(index + w.count)]) == w
    }
}
