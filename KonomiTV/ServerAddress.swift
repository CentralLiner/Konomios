import Foundation

/// A validated HTTPS endpoint, including an optional reverse-proxy base path.
struct ServerAddress: Codable, Hashable {
    let url: URL

    var origin: String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host else { return "" }
        let renderedHost = Self.renderHost(host)
        let port = components.port ?? 443
        return "https://\(renderedHost)\(port == 443 ? "" : ":\(port)")"
    }

    init(input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }), !trimmed.contains("\\") else { throw ValidationError.invalidURL }
        guard var components = URLComponents(string: trimmed) else { throw ValidationError.invalidURL }
        guard components.scheme?.lowercased() == "https" else { throw ValidationError.httpsRequired }
        guard let host = components.host, !host.isEmpty,
              Self.validHost(host), Self.validPercentEncoding(trimmed) else { throw ValidationError.invalidURL }
        guard components.user == nil, components.password == nil else { throw ValidationError.credentialsNotAllowed }
        guard components.query == nil, components.fragment == nil else { throw ValidationError.queryOrFragmentNotAllowed }
        if let port = components.port, !(1...65535).contains(port) { throw ValidationError.invalidPort }

        // An escaped authority can obscure the actual server name in the editor.
        guard let authority = trimmed.split(separator: "/", omittingEmptySubsequences: false).dropFirst(2).first,
              !authority.contains("%") else { throw ValidationError.invalidURL }
        if authority.hasSuffix(":") { throw ValidationError.invalidPort }
        guard Self.safePath(components.percentEncodedPath) else { throw ValidationError.invalidPath }

        components.scheme = "https"
        components.host = host.lowercased()
        if components.port == 443 { components.port = nil }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        } else if !components.percentEncodedPath.hasSuffix("/") {
            components.percentEncodedPath += "/"
        }
        guard let normalized = components.url else { throw ValidationError.invalidURL }
        self.url = normalized
    }

    /// HTTPS, host and effective port must match. Paths, queries and fragments are irrelevant.
    func sameOrigin(_ candidate: URL) -> Bool {
        guard let actual = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: url, resolvingAgainstBaseURL: false),
              actual.scheme?.lowercased() == "https",
              actual.user == nil, actual.password == nil,
              let actualHost = actual.host, let expectedHost = expected.host,
              Self.validHost(actualHost),
              actualHost.lowercased() == expectedHost.lowercased(),
              (actual.port ?? 443) == (expected.port ?? 443) else { return false }
        return true
    }

    /// Limits web navigation to the configured reverse-proxy mount point.
    func containsNavigation(_ candidate: URL) -> Bool {
        guard sameOrigin(candidate),
              let actual = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              let expected = URLComponents(url: url, resolvingAgainstBaseURL: false),
              Self.safePath(actual.percentEncodedPath),
              let actualPath = actual.percentEncodedPath.removingPercentEncoding,
              let basePath = expected.percentEncodedPath.removingPercentEncoding else { return false }
        if basePath == "/" { return true }
        // Also allow the mount point itself, so a server can redirect it to its trailing slash.
        return actualPath == String(basePath.dropLast()) || actualPath.hasPrefix(basePath)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(input: value)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: error.localizedDescription)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(url.absoluteString)
    }

    private static func renderHost(_ host: String) -> String {
        if host.contains(":"), !host.hasPrefix("[") { return "[\(host.lowercased())]" }
        return host.lowercased()
    }

    private static func validHost(_ host: String) -> Bool {
        let value = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        guard !value.isEmpty, !value.contains("%") else { return false }
        if value.contains(":") { return validIPv6(value) }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, value.utf8.count <= 253 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                && label.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }
        }
    }

    private static func safePath(_ encodedPath: String) -> Bool {
        var path = encodedPath
        // Reject nested escapes as well: some reverse proxies decode a path more than once.
        for _ in 0..<4 {
            guard validPercentEncoding(path),
                  !path.lowercased().contains("%2f"),
                  !path.lowercased().contains("%5c"),
                  let decoded = path.removingPercentEncoding,
                  !decoded.contains("\\"),
                  !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !decoded.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else { return false }
            if !decoded.contains("%") { return true }
            path = decoded
        }
        return false
    }

    private static func validIPv6(_ value: String) -> Bool {
        guard value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF:.").contains($0) }) else { return false }
        let halves = value.components(separatedBy: "::")
        guard halves.count <= 2 else { return false }
        if halves.count == 1, value.hasPrefix(":") || value.hasSuffix(":") { return false }
        let components = halves.flatMap { $0.isEmpty ? [] : $0.components(separatedBy: ":") }
        var size = 0
        for (index, component) in components.enumerated() {
            if component.contains(".") {
                guard index == components.count - 1 else { return false }
                let octets = component.components(separatedBy: ".")
                guard octets.count == 4, octets.allSatisfy({
                    !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber })
                        && (Int($0).map { (0...255).contains($0) } ?? false)
                }) else { return false }
                size += 2
            } else {
                guard (1...4).contains(component.count), component.utf8.allSatisfy(isHex) else { return false }
                size += 1
            }
        }
        return halves.count == 2 ? size < 8 : size == 8
    }

    private static func validPercentEncoding(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) else { return false }
                index += 3
            } else {
                index += 1
            }
        }
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    enum ValidationError: LocalizedError {
        case empty, invalidURL, httpsRequired, credentialsNotAllowed, queryOrFragmentNotAllowed, invalidPort, invalidPath

        var errorDescription: String? {
            switch self {
            case .empty: return "KonomiTVサーバーのURLを入力してください。"
            case .invalidURL: return "正しいサーバーURLを入力してください。例のように、https://から始まるURLを使用します。"
            case .httpsRequired: return "HTTPSのURLが必要です。KonomiTVのHTTPS接続用URLを入力してください。"
            case .credentialsNotAllowed: return "ユーザー名・パスワードを含むURLは使用できません。ログインは接続後に行ってください。"
            case .queryOrFragmentNotAllowed: return "URLの「?」や「#」以降を除いて、KonomiTVのトップページURLを入力してください。"
            case .invalidPort: return "ポート番号は1〜65535の範囲で指定してください。"
            case .invalidPath: return "URLのパスに「..」やエンコードされた区切り文字は使用できません。"
            }
        }
    }
}
