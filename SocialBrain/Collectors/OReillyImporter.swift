import Foundation

/// Parses an O'Reilly Payment Remittance Advice `.eml` (or `.rtf`) file into a `PlatformData` snapshot.
///
/// O'Reilly sends monthly Payment Remittance Advice emails from payables@oreilly.com.
/// Save the email as `.eml` from Mail.app (File → Save As) and import it here.
///
/// Key metrics produced:
/// - `payment_amount`   – payment total (Double)
/// - `payment_currency` – ISO currency code, e.g. "USD" (String)
/// - `payment_date`     – ISO date string, e.g. "2026-03-31" (String)
/// - `doc_number`       – paper document number (String, if present)
/// - `line_item_count`  – number of royalty line items (Int, if present)
struct OReillyImporter {

    enum ImportError: LocalizedError {
        case emptyFile
        case missingRequiredFields

        var errorDescription: String? {
            switch self {
            case .emptyFile:
                "The selected file contains no data."
            case .missingRequiredFields:
                "The file does not appear to be an O'Reilly Payment Remittance Advice email. " +
                "Make sure you have saved the payment advice email as .eml from Mail.app."
            }
        }
    }

    func parse(data: Data) throws -> PlatformData {
        guard !data.isEmpty else { throw ImportError.emptyFile }

        let raw = String(data: data, encoding: .utf8)
               ?? String(data: data, encoding: .isoLatin1)
               ?? ""
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyFile
        }

        let tokens: [String]
        if raw.hasPrefix("{\\rtf") {
            tokens = tokensFromRTF(raw)
        } else {
            tokens = tokensFromEML(raw)
        }

        return try buildPlatformData(from: tokens)
    }

    // MARK: - EML / MIME parsing

    private func tokensFromEML(_ raw: String) -> [String] {
        let html = extractHTMLBody(raw) ?? raw
        return htmlToTokens(html)
    }

    private func extractHTMLBody(_ raw: String) -> String? {
        extractHTMLFromMIMEPart(raw, usedBoundaries: [])
    }

    /// Recursively walks MIME parts (handles nested multipart/related, multipart/alternative, etc.).
    /// `usedBoundaries` prevents re-splitting on a boundary we already consumed, breaking infinite loops.
    private func extractHTMLFromMIMEPart(_ part: String, usedBoundaries: Set<String>) -> String? {
        // Only look at the headers section (before the first blank line) for Content-Type.
        let headerEnd = part.range(of: "\n\n")?.lowerBound ?? part.endIndex
        let headerSection = String(part[..<headerEnd]).lowercased()

        // Direct text/html part — Content-Type must be in the headers, not the body.
        if headerSection.contains("content-type: text/html") ||
           headerSection.contains("content-type:text/html") {
            return decodeMIMEPart(part)
        }

        // Nested multipart — recurse into sub-parts using a fresh boundary.
        if let boundary = mimeBoundary(part), !usedBoundaries.contains(boundary) {
            let delimiter = "--" + boundary
            let subParts = part.components(separatedBy: delimiter)
            let newUsed = usedBoundaries.union([boundary])
            for subPart in subParts {
                if let html = extractHTMLFromMIMEPart(subPart, usedBoundaries: newUsed) {
                    return html
                }
            }
        }

        // Non-multipart fallback: raw HTML body passed directly.
        if part.lowercased().contains("<html") {
            return bodyAfterHeaders(part)
        }
        return nil
    }

    /// Extracts the boundary value from the headers section only (before the first blank line).
    /// Ignoring body content prevents false matches and infinite recursion.
    private func mimeBoundary(_ raw: String) -> String? {
        let headerEnd = raw.range(of: "\r\n\r\n")?.lowerBound
                     ?? raw.range(of: "\n\n")?.lowerBound
                     ?? raw.endIndex
        let headerText = String(raw[..<headerEnd])
        for line in headerText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().contains("boundary=") else { continue }
            guard let range = trimmed.range(of: "boundary=", options: .caseInsensitive) else { continue }
            var value = String(trimmed[range.upperBound...])
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \r\n"))
            if let semi = value.firstIndex(of: ";") { value = String(value[..<semi]) }
            value = value.trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func decodeMIMEPart(_ part: String) -> String {
        let body = bodyAfterHeaders(part)
        let headerSection = part.prefix(
            upTo: part.range(of: "\n\n")?.lowerBound ?? part.endIndex
        ).lowercased()

        if headerSection.contains("base64") {
            let stripped = body.replacingOccurrences(of: "\r\n", with: "")
                               .replacingOccurrences(of: "\n", with: "")
            if let decoded = Data(base64Encoded: stripped),
               let str = String(data: decoded, encoding: .utf8)
                      ?? String(data: decoded, encoding: .isoLatin1) {
                return str
            }
        } else if headerSection.contains("quoted-printable") {
            return decodeQuotedPrintable(body)
        }
        return body
    }

    private func bodyAfterHeaders(_ s: String) -> String {
        if let r = s.range(of: "\r\n\r\n") { return String(s[r.upperBound...]) }
        if let r = s.range(of: "\n\n")     { return String(s[r.upperBound...]) }
        return s
    }

    private func decodeQuotedPrintable(_ input: String) -> String {
        var result = ""
        var i = input.startIndex
        while i < input.endIndex {
            let ch = input[i]
            if ch == "=" {
                let j = input.index(after: i)
                if j < input.endIndex {
                    let ch2 = input[j]
                    // Soft line break
                    if ch2 == "\r" || ch2 == "\n" {
                        let k = input.index(after: j)
                        i = (ch2 == "\r" && k < input.endIndex && input[k] == "\n")
                            ? input.index(after: k) : k
                        continue
                    }
                    // Hex escape
                    let end = input.index(j, offsetBy: 2, limitedBy: input.endIndex) ?? input.endIndex
                    if end <= input.endIndex,
                       let byte = UInt8(input[j..<end], radix: 16) {
                        result.append(Character(UnicodeScalar(byte)))
                        i = end
                        continue
                    }
                }
            }
            result.append(ch)
            i = input.index(after: i)
        }
        return result
    }

    // MARK: - HTML → token list

    private func htmlToTokens(_ html: String) -> [String] {
        var tokens: [String] = []
        var i = html.startIndex
        var current = ""
        var inTag = false
        var inSkipBlock = false
        var tagContent = ""

        func flush() {
            let t = htmlEntitiesDecode(current).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { tokens.append(t) }
            current = ""
        }

        while i < html.endIndex {
            let ch = html[i]
            if ch == "<" {
                flush(); inTag = true; tagContent = ""
                i = html.index(after: i); continue
            }
            if ch == ">" && inTag {
                inTag = false
                let tag = tagContent.trimmingCharacters(in: .whitespaces).lowercased()
                let first = tag.components(separatedBy: .whitespaces).first ?? ""
                let closing = first.hasPrefix("/")
                let name = closing ? String(first.dropFirst()) : first
                if ["style", "script"].contains(name) { inSkipBlock = !closing }
                i = html.index(after: i); continue
            }
            if inTag {
                tagContent.append(ch)
            } else if !inSkipBlock {
                current.append(ch)
            }
            i = html.index(after: i)
        }
        flush()
        return tokens
    }

    private func htmlEntitiesDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "&nbsp;", with: " ")
         .replacingOccurrences(of: "&amp;", with: "&")
         .replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;", with: "'")
    }

    // MARK: - RTF parsing

    private func tokensFromRTF(_ raw: String) -> [String] {
        var text = raw
        // Strip RTF control words (\word or \word-n or \word n)
        text = (try? NSRegularExpression(pattern: #"\\[a-z*]+-?\d* ?"#))
            .map { $0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") }
            ?? text
        // Strip braces and backslashes
        text = text.replacingOccurrences(of: "{", with: " ")
                   .replacingOccurrences(of: "}", with: " ")
                   .replacingOccurrences(of: "\\", with: " ")
        // Normalise whitespace
        text = (try? NSRegularExpression(pattern: #"\s+"#))
            .map { $0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ") }
            ?? text
        // For RTF the tokens are whitespace-separated words; the caller must
        // handle multi-word labels differently, but we use the same after()
        // logic — it won't find multi-word labels. Use a regex path instead.
        return text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    // MARK: - Field extraction

    private func buildPlatformData(from tokens: [String]) throws -> PlatformData {
        // label-then-value: find the token immediately after a label token
        func after(_ label: String) -> String? {
            for (i, t) in tokens.enumerated() where t == label {
                if i + 1 < tokens.count { return tokens[i + 1] }
            }
            return nil
        }

        // For RTF the date arrives as 3 separate tokens ("Mar", "31,", "2026")
        // so we also try joining the next 3 tokens after the label word "Date".
        func afterRTFDate() -> String? {
            for (i, t) in tokens.enumerated() where t == "Date" {
                guard i >= 1, tokens[i - 1] == "Payment" else { continue }
                let slice = tokens[min(i + 1, tokens.endIndex)..<min(i + 4, tokens.endIndex)]
                let joined = slice.joined(separator: " ")
                if !joined.isEmpty { return joined }
            }
            return nil
        }

        let rawDate   = after("Payment Date")   ?? afterRTFDate()
        let rawAmount = after("Payment Amount")

        guard let rawDate,
              let rawAmount,
              let paymentDate = parsePaymentDate(rawDate),
              let amount = Double(rawAmount.replacingOccurrences(of: ",", with: ""))
        else {
            throw ImportError.missingRequiredFields
        }

        let currency  = after("Payment Currency") ?? "USD"
        let docNumber = after("Paper Document Number") ?? ""

        let lineItemCount = tokens.filter {
            $0.range(of: #"^[A-Z]+-\d+$"#, options: .regularExpression) != nil
        }.count

        var metrics: [String: MetricValue] = [
            "payment_amount":   .double(amount),
            "payment_currency": .string(currency),
            "payment_date":     .string(paymentDate),
        ]
        if !docNumber.isEmpty  { metrics["doc_number"]       = .string(docNumber) }
        if lineItemCount > 0   { metrics["line_item_count"]  = .int(lineItemCount) }
        return PlatformData(platform: .oreilly, metrics: metrics)
    }

    private func parsePaymentDate(_ s: String) -> String? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let outFmt = DateFormatter()
        outFmt.locale = Locale(identifier: "en_US_POSIX")
        outFmt.dateFormat = "yyyy-MM-dd"

        // "Mar 31, 2026" (EML / HTML)
        fmt.dateFormat = "MMM d, yyyy"
        if let d = fmt.date(from: s) { return outFmt.string(from: d) }
        fmt.dateFormat = "MMM dd, yyyy"
        if let d = fmt.date(from: s) { return outFmt.string(from: d) }

        // "Mar 31 2026" or "Mar 31, 2026" after comma strip (RTF joined)
        let clean = s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        fmt.dateFormat = "MMM d yyyy"
        if let d = fmt.date(from: clean) { return outFmt.string(from: d) }
        fmt.dateFormat = "MMM dd yyyy"
        if let d = fmt.date(from: clean) { return outFmt.string(from: d) }

        return nil
    }
}
