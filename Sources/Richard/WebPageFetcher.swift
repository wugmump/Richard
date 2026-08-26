import Foundation

/// Plain-text result from a web page fetch.
struct WebFetchResult {
    /// Original URL requested by the model or inferred from the user's message.
    let requestedURL: String
    /// Final URL after Foundation follows redirects.
    let finalURL: String?
    /// HTTP status code, when the response was HTTP.
    let statusCode: Int?
    /// Best-effort page title extracted from the HTML.
    let title: String?
    /// Readable text extracted from the response body.
    let text: String
    /// Error text for failed fetches.
    let error: String?
}

/// Subset of Wikipedia's REST summary payload.
private struct WikipediaSummary: Decodable {
    let title: String?
    let description: String?
    let extract: String?
}

/// Small web fetch helper used to ground URL and current-events answers.
///
/// This intentionally fetches only HTTP(S) pages and returns compact plain text.
/// The language model never gets raw HTML, scripts, styles, or large payloads.
enum WebPageFetcher {
    /// Maximum number of response bytes kept before text extraction.
    private static let maximumBytes = 1_500_000
    /// Maximum extracted text sent back into the model context.
    private static let maximumTextLength = 6_000

    /// Fetches an HTTP(S) URL and extracts compact readable text.
    static func fetch(_ rawURL: String) async -> WebFetchResult {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return WebFetchResult(
                requestedURL: trimmed,
                finalURL: nil,
                statusCode: nil,
                title: nil,
                text: "",
                error: "Only valid http:// and https:// URLs can be fetched."
            )
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Richard/1.0 (+local macOS app)", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html, text/plain;q=0.9, */*;q=0.2", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let limitedData = data.count > maximumBytes ? data.prefix(maximumBytes) : data[...]
            let body = String(data: Data(limitedData), encoding: .utf8)
                ?? String(data: Data(limitedData), encoding: .isoLatin1)
                ?? ""
            let httpResponse = response as? HTTPURLResponse
            let pageTitle = title(from: body)
            let extracted = extractText(from: body)
            let summary = await wikipediaSummary(for: url)
            let text = [summary, extracted].compactMap { $0 }.joined(separator: "\n\nPage text:\n")

            return WebFetchResult(
                requestedURL: trimmed,
                finalURL: response.url?.absoluteString,
                statusCode: httpResponse?.statusCode,
                title: pageTitle,
                text: clamp(text.isEmpty ? body : text, limit: maximumTextLength),
                error: nil
            )
        } catch {
            return WebFetchResult(
                requestedURL: trimmed,
                finalURL: nil,
                statusCode: nil,
                title: nil,
                text: "",
                error: error.localizedDescription
            )
        }
    }

    /// Formats a fetch result for insertion as a system/tool context message.
    static func formatted(_ result: WebFetchResult) -> String {
        if let error = result.error {
            return """
            Web fetch failed.
            Requested URL: \(result.requestedURL)
            Error: \(error)
            """
        }

        return """
        Web fetch completed.
        Authority: This is real fetched web content from the app. If this conflicts with training memory or older chat, the fetched content wins.
        Existence rule: HTTP status 200 means the requested page exists.
        Requested URL: \(result.requestedURL)
        Final URL: \(result.finalURL ?? "unknown")
        HTTP status: \(result.statusCode.map(String.init) ?? "unknown")
        Title: \(result.title ?? "unknown")
        Extracted text:
        \(result.text.isEmpty ? "[no readable text extracted]" : result.text)
        """
    }

    /// Uses Wikipedia's summary endpoint for cleaner lead text on wiki pages.
    private static func wikipediaSummary(for url: URL) async -> String? {
        guard let host = url.host(percentEncoded: false),
              host.hasSuffix("wikipedia.org"),
              url.path(percentEncoded: false).hasPrefix("/wiki/") else {
            return nil
        }

        let title = String(url.path(percentEncoded: false).dropFirst("/wiki/".count))
        guard !title.isEmpty,
              let encodedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let summaryURL = URL(string: "https://\(host)/api/rest_v1/page/summary/\(encodedTitle)") else {
            return nil
        }

        do {
            var request = URLRequest(url: summaryURL)
            request.timeoutInterval = 12
            request.setValue("Richard/1.0 (+local macOS app)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                return nil
            }

            let decoded = try JSONDecoder().decode(WikipediaSummary.self, from: data)
            let pieces = [
                decoded.title.map { "Wikipedia summary title: \($0)" },
                decoded.description.map { "Description: \($0)" },
                decoded.extract.map { "Summary: \($0)" }
            ].compactMap { $0 }
            return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
        } catch {
            return nil
        }
    }

    /// Removes markup and normalizes whitespace using conservative regex passes.
    private static func extractText(from html: String) -> String {
        var text = html
        text = replace(text, pattern: "(?is)<script\\b[^>]*>.*?</script>", with: " ")
        text = replace(text, pattern: "(?is)<style\\b[^>]*>.*?</style>", with: " ")
        text = replace(text, pattern: "(?is)<noscript\\b[^>]*>.*?</noscript>", with: " ")
        text = replace(text, pattern: "(?is)<!--.*?-->", with: " ")
        text = replace(text, pattern: "(?is)<[^>]+>", with: " ")
        text = decodeEntities(text)
        return normalizeWhitespace(text)
    }

    /// Extracts the first HTML title if one exists.
    private static func title(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<title[^>]*>(.*?)</title>") else {
            return nil
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let titleRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        let value = normalizeWhitespace(decodeEntities(String(html[titleRange])))
        return value.isEmpty ? nil : value
    }

    /// Runs one regular-expression replacement.
    private static func replace(_ text: String, pattern: String, with replacement: String) -> String {
        text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }

    /// Handles common HTML entities and numeric entity references.
    private static func decodeEntities(_ text: String) -> String {
        var decoded = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")

        if let regex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);") {
            let matches = regex.matches(
                in: decoded,
                range: NSRange(decoded.startIndex..<decoded.endIndex, in: decoded)
            ).reversed()

            for match in matches {
                guard match.numberOfRanges > 1,
                      let fullRange = Range(match.range(at: 0), in: decoded),
                      let valueRange = Range(match.range(at: 1), in: decoded) else {
                    continue
                }
                let rawValue = String(decoded[valueRange])
                let radix = rawValue.hasPrefix("x") ? 16 : 10
                let digits = rawValue.hasPrefix("x") ? String(rawValue.dropFirst()) : rawValue
                guard let scalarValue = UInt32(digits, radix: radix),
                      let scalar = UnicodeScalar(scalarValue) else {
                    continue
                }
                decoded.replaceSubrange(fullRange, with: String(Character(scalar)))
            }
        }

        return decoded
    }

    /// Converts runs of whitespace to single spaces.
    private static func normalizeWhitespace(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Caps text to a predictable size for local model latency.
    private static func clamp(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "\n[web text truncated]"
    }
}
