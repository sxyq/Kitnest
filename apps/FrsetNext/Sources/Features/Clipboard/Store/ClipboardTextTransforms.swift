import Foundation

public enum ClipboardOutputFormat: String, CaseIterable {
    case merged = "换行合并"
    case numbered = "编号清单"
}

/// 近期组合窗和主列表多选共用正文生成；转换不写历史或剪贴板。
enum ClipboardTextTransforms {
    static func combine(_ texts: [String], format: ClipboardOutputFormat) -> String {
        if format == .merged { return texts.joined(separator: "\n") }
        return texts.enumerated().map { index, text in
            let prefix = "\(index + 1). "
            return prefix + text.replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: prefix.count))
        }.joined(separator: "\n")
    }

    static func deduplicate(_ text: String, ignoreCase: Bool, trim: Bool) -> (text: String, total: Int, removed: Int) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        var seen = Set<String>()
        let kept = lines.filter { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            var key = trim ? line.trimmingCharacters(in: .whitespaces) : line
            if ignoreCase { key = key.lowercased() }
            return seen.insert(key).inserted
        }
        return (kept.joined(separator: "\n"), lines.count, lines.count - kept.count)
    }

    static func cleanLink(_ text: String) -> (text: String, removed: Int, signed: Bool) {
        guard let queryStart = text.firstIndex(of: "?") else { return (text, 0, false) }
        if let anchor = text.firstIndex(of: "#"), anchor < queryStart { return (text, 0, false) }
        let fragment = text[queryStart...].firstIndex(of: "#") ?? text.endIndex
        let query = text[text.index(after: queryStart)..<fragment]
        let parts = query.split(separator: "&", omittingEmptySubsequences: false)
        func name(_ part: Substring) -> String {
            let raw = String(part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)[0])
            return (raw.removingPercentEncoding ?? raw).lowercased()
        }
        let signed = parts.contains { ["sig", "sign", "signature", "oauth_signature", "x-amz-signature", "x-goog-signature", "hmac"].contains(name($0)) }
        if signed { return (text, 0, true) }
        let kept = parts.filter { part in
            let key = name(part)
            return !key.hasPrefix("utm_") && !["fbclid", "gclid", "msclkid"].contains(key)
        }
        let removed = parts.count - kept.count
        if removed == 0 { return (text, 0, false) }
        let result = String(text[..<queryStart]) + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + text[fragment...]
        return (result, removed, false)
    }

    static func organizeOCR(_ text: String) -> (text: String, merged: Int) {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        func structured(_ line: String) -> Bool {
            line.isEmpty || line.hasPrefix(" ") || line.hasPrefix("\t") || line.contains("|") ||
            line.range(of: "^(#|[-*•]\\s|[0-9]+[.)、]\\s)", options: .regularExpression) != nil
        }
        func chinese(_ character: Character) -> Bool {
            character.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
        }
        var result: [String] = []
        var merged = 0
        for line in lines {
            guard let previous = result.last, let end = previous.last, let first = line.first,
                  !structured(previous), !structured(line), !"。！？.!?:：;；".contains(end) else {
                result.append(line); continue
            }
            let isChinese = previous.count >= 8 && chinese(end) && chinese(first)
            let isEnglish = previous.count >= 24 && end.isLetter && first.isLowercase && !chinese(end)
            if isChinese || isEnglish {
                result[result.count - 1] += (isEnglish ? " " : "") + line
                merged += 1
            } else { result.append(line) }
        }
        return (result.joined(separator: "\n"), merged)
    }
}
