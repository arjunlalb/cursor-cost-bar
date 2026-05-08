import Foundation
import OSLog

private let logger = Logger(subsystem: "com.cursormeter", category: "general")

enum Log {
    // Redacted output is the security boundary, so the resulting string is safe
    // to surface in Console.app and `log collect` archives. Mark as `.public`
    // explicitly — Swift string interpolation defaults dynamic content to
    // `<private>`, which would hide already-scrubbed messages from operators.
    static func info(_ message: String) {
        logger.info("\(LogRedactor.redact(message), privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(LogRedactor.redact(message), privacy: .public)")
    }
}

enum LogRedactor {
    private static let emailRegex = try! NSRegularExpression(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        options: [.caseInsensitive])
    private static let cookieRegex = try! NSRegularExpression(
        pattern: #"(?i)(cookie\s*:\s*)([^\r\n]+)"#)
    private static let authRegex = try! NSRegularExpression(
        pattern: #"(?i)(authorization\s*:\s*)([^\r\n]+)"#)
    private static let bearerRegex = try! NSRegularExpression(
        pattern: #"(?i)\bbearer\s+[a-z0-9+/._\-]+=*"#)
    // JWT: three base64url segments separated by dots, prefixed with `eyJ`.
    private static let jwtRegex = try! NSRegularExpression(
        pattern: #"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#)
    // Generic key=value tokens (cookies, query params, body fields) carrying credentials.
    // Captures the key so it stays visible while the value is redacted.
    private static let tokenAssignmentRegex = try! NSRegularExpression(
        pattern: #"(?i)\b((?:[A-Za-z0-9_-]*(?:session-token|cookie|auth|token))=)([^;\s&]+)"#)

    static func redact(_ text: String) -> String {
        var output = text
        output = replace(emailRegex, in: output, with: "<redacted-email>")
        output = replace(cookieRegex, in: output, with: "$1<redacted>")
        output = replace(authRegex, in: output, with: "$1<redacted>")
        output = replace(bearerRegex, in: output, with: "Bearer <redacted>")
        output = replace(jwtRegex, in: output, with: "<redacted-jwt>")
        output = replace(tokenAssignmentRegex, in: output, with: "$1<redacted>")
        return output
    }

    private static func replace(
        _ regex: NSRegularExpression, in text: String, with template: String
    ) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}
