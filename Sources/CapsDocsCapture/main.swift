import AppKit
import ApplicationServices
import CommonCrypto
import CoreGraphics
import Darwin
import Foundation

// MARK: - Constants

private let appName = "CapsDocsCapture"
private let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".caps-docs-capture", isDirectory: true)
private let targetFile = supportDirectory.appendingPathComponent("target.json")
private let tokenFile = supportDirectory.appendingPathComponent("google-tokens.json")
private let logFile = supportDirectory.appendingPathComponent("capture.log")
private let launchAgentFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/com.alessandro.CapsDocsCapture.plist")
private let karabinerCLIPath = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
private let karabinerEnabledVariable = "caps_docs_capture_enabled"
private let daemonAutoQuitInterval: TimeInterval = 60 * 60

// A run of six zero-width spaces. Invisible in the document, but unique enough
// that the Docs API can locate it reliably and treat it as the live insertion
// anchor.
private let anchorMarker = String(repeating: "\u{200B}", count: 6)

private let docsScope = "https://www.googleapis.com/auth/documents"

private let keyCodeC: CGKeyCode = 8
private let keyCodeV: CGKeyCode = 9
private let keyCodeL: CGKeyCode = 37
private let keyCodeEscape: CGKeyCode = 53
private let keyCodeCommand: CGKeyCode = 55
private let keyCodeLeftArrow: CGKeyCode = 123

// MARK: - Stored models

private struct Target: Codable {
    var documentId: String
    var title: String
    var hasAnchor: Bool
    var createdAt: Date
}

private struct GoogleTokens: Codable {
    var clientId: String
    var clientSecret: String
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

// MARK: - Clipboard

private final class PasteboardSnapshot {
    private let itemData: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard = .general) {
        itemData = (pasteboard.pasteboardItems ?? []).map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    values[type] = data
                }
            }
            return values
        }
    }

    func restore(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let items = itemData.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}

// MARK: - Capture (Caps Lock)

private func captureOnce() -> Bool {
    ensureSupportDirectory()
    log("capture begin")

    guard let token = validAccessToken() else {
        log("capture failed: not connected to Google")
        notify(title: "CapsDocsCapture not connected",
               body: "Run --google-auth to connect Google Docs.")
        NSSound.beep()
        return false
    }

    guard let target = loadTarget() else {
        log("capture failed: no target Doc")
        notify(title: "No target Doc",
               body: "Press Shift-Caps Lock in a Google Doc first.")
        NSSound.beep()
        return false
    }

    let snapshot = PasteboardSnapshot()
    let selected = readSelectedText()
    snapshot.restore()

    guard let raw = selected,
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        log("capture failed: nothing selected")
        NSSound.beep()
        return false
    }
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    log("captured \(text.count) chars")

    guard let document = getDocument(target.documentId, token: token) else {
        log("capture failed: could not read target Doc")
        notify(title: "Could not open target Doc",
               body: "Check Doc sharing or re-run --set-target.")
        NSSound.beep()
        return false
    }

    let model = documentModel(document)
    let requests: [[String: Any]]
    if target.hasAnchor, let anchorIndex = model.anchorIndex {
        requests = [["insertText": ["text": text + "\n", "location": ["index": anchorIndex]]]]
        log("inserting \(text.count) chars at anchor index \(anchorIndex)")
    } else {
        let index = max(1, model.endIndex - 1)
        requests = [["insertText": ["text": "\n" + text, "location": ["index": index]]]]
        log("appending \(text.count) chars at end index \(index)")
    }

    guard batchUpdate(target.documentId, requests: requests, token: token) else {
        log("capture failed: batchUpdate rejected")
        notify(title: "Could not write to Doc", body: "The capture was not saved.")
        NSSound.beep()
        return false
    }

    log("capture done")
    return true
}

private func readSelectedText() -> String? {
    if let text = accessibilitySelectedText() {
        return text
    }
    return copySelectedText()
}

private func accessibilitySelectedText() -> String? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    var focusedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
          let focusedValue else {
        log("ax: no focused element in \(app.localizedName ?? "unknown")")
        return nil
    }

    let element = focusedValue as! AXUIElement
    var selectedValue: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedValue) == .success,
          let text = selectedValue as? String else {
        log("ax: no selected text in \(app.localizedName ?? "unknown")")
        return nil
    }

    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return nil
    }
    log("ax: read \(text.count) chars from \(app.localizedName ?? "unknown")")
    return text
}

private func copySelectedText(timeout: TimeInterval = 1.0) -> String? {
    let pasteboard = NSPasteboard.general
    let sentinel = "__CDC_\(UUID().uuidString)__"
    pasteboard.clearContents()
    pasteboard.setString(sentinel, forType: .string)
    let startChangeCount = pasteboard.changeCount

    keyCombo(keyCodeC, flags: .maskCommand)

    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.03)
        let value = pasteboard.string(forType: .string)
        if pasteboard.changeCount != startChangeCount, value != sentinel {
            return value
        }
    }
    let fallback = pasteboard.string(forType: .string)
    return fallback == sentinel ? nil : fallback
}

// MARK: - Set target (Shift-Caps Lock)

private func setTargetFromFrontTab() -> Bool {
    ensureSupportDirectory()

    guard let token = validAccessToken() else {
        fputs("Not connected to Google. Run: CapsDocsCapture --google-auth <client_secret.json>\n", stderr)
        log("set-target failed: not connected to Google")
        NSSound.beep()
        return false
    }

    // Place the anchor while the caret is still in the Doc body, then read the
    // browser's address bar with the keyboard. AppleScript tab control is
    // unreliable in some browsers (notably ChatGPT Atlas), so it is not used.
    let snapshot = PasteboardSnapshot()
    placeAnchorAtCursor()
    let url = frontTabURLViaKeyboard()
    snapshot.restore()

    guard let url, !url.isEmpty else {
        fputs("Could not read the front browser tab's URL.\n", stderr)
        log("set-target failed: could not read front tab URL")
        NSSound.beep()
        return false
    }
    guard let documentId = googleDocumentID(url) else {
        fputs("The front tab is not a Google Doc: \(url)\n", stderr)
        log("set-target failed: front tab is not a Google Doc: \(url)")
        NSSound.beep()
        return false
    }
    log("set-target: front tab document id \(documentId)")
    return saveTargetDocument(documentId: documentId, token: token, anchorPlaced: true)
}

private func setTargetByURL(_ argument: String) -> Bool {
    ensureSupportDirectory()

    guard let token = validAccessToken() else {
        fputs("Not connected to Google. Run: CapsDocsCapture --google-auth <client_secret.json>\n", stderr)
        return false
    }
    guard let documentId = googleDocumentID(argument) else {
        fputs("Could not read a Google document ID from: \(argument)\n", stderr)
        return false
    }
    return saveTargetDocument(documentId: documentId, token: token, anchorPlaced: false)
}

private func saveTargetDocument(documentId: String, token: String, anchorPlaced: Bool) -> Bool {
    // Verify the connected Google account can actually open this Doc before
    // saving it. A target that 403s is worse than no change at all.
    guard let document = getDocument(documentId, token: token) else {
        fputs("""
        Could not open that Google Doc (\(documentId)).
        The connected Google account does not have access to it.
        Open the Doc with the account you connected to CapsDocsCapture, share the
        Doc with that account, or re-run --google-auth with the right account.
        The previous target was left unchanged.

        """, stderr)
        log("set-target failed: getDocument denied for \(documentId)")
        NSSound.beep()
        return false
    }

    let title = (document["title"] as? String) ?? "Google Doc"
    var hasAnchor = false
    if anchorPlaced {
        hasAnchor = documentModel(document).anchorIndex != nil
        var attempt = 0
        while !hasAnchor, attempt < 10 {
            attempt += 1
            Thread.sleep(forTimeInterval: 0.3)
            if let refreshed = getDocument(documentId, token: token),
               documentModel(refreshed).anchorIndex != nil {
                hasAnchor = true
                log("anchor confirmed after \(attempt) retr(ies)")
            }
        }
        if !hasAnchor {
            log("anchor not confirmed; using append-to-end mode")
        }
    }

    let target = Target(documentId: documentId, title: title, hasAnchor: hasAnchor, createdAt: Date())
    guard saveTarget(target) else {
        fputs("Could not save the target.\n", stderr)
        return false
    }

    print("Saved target Doc: \(title)")
    print(hasAnchor
        ? "Captures will be inserted at your cursor anchor."
        : "Captures will be appended to the end of the document.")
    return true
}

private func placeAnchorAtCursor() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(anchorMarker, forType: .string)
    Thread.sleep(forTimeInterval: 0.05)

    keyCombo(keyCodeV, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 0.25)

    // Move the editor caret back in front of the anchor so the user's own
    // typing and the next capture both land at the same spot.
    for _ in 0..<anchorMarker.utf16.count {
        keyCombo(keyCodeLeftArrow, flags: [])
    }
    Thread.sleep(forTimeInterval: 0.15)
}

// Reads the front browser tab's URL via the keyboard: Cmd-L selects the
// address bar, Cmd-C copies it, Esc restores the page. Works on any browser,
// including ones whose AppleScript dictionary is unreliable.
private func frontTabURLViaKeyboard() -> String? {
    let pasteboard = NSPasteboard.general
    let sentinel = "__CDC_URL_\(UUID().uuidString)__"
    pasteboard.clearContents()
    pasteboard.setString(sentinel, forType: .string)
    let startChangeCount = pasteboard.changeCount

    keyCombo(keyCodeL, flags: .maskCommand)
    Thread.sleep(forTimeInterval: 0.2)
    keyCombo(keyCodeC, flags: .maskCommand)

    var url: String?
    let deadline = Date().addingTimeInterval(1.5)
    while Date() < deadline {
        Thread.sleep(forTimeInterval: 0.03)
        if pasteboard.changeCount != startChangeCount {
            let value = pasteboard.string(forType: .string)
            if let value, value != sentinel {
                url = value
                break
            }
        }
    }

    keyCombo(keyCodeEscape, flags: [])
    Thread.sleep(forTimeInterval: 0.1)
    return url?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func googleDocumentID(_ urlOrId: String) -> String? {
    if let range = urlOrId.range(of: "/document/d/") {
        let afterPrefix = urlOrId[range.upperBound...]
        if let id = afterPrefix.split(separator: "/").first.map(String.init), !id.isEmpty {
            return id
        }
    }
    let trimmed = urlOrId.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.contains("/"), !trimmed.contains(" "), trimmed.count >= 20 {
        return trimmed
    }
    return nil
}

// MARK: - Google Docs document model

private struct DocumentModel {
    var anchorIndex: Int?
    var endIndex: Int
}

private func documentModel(_ document: [String: Any]) -> DocumentModel {
    var units: [UInt16] = []
    var indexMap: [Int] = []
    var endIndex = 1

    if let body = document["body"] as? [String: Any],
       let content = body["content"] as? [[String: Any]] {
        for element in content {
            if let elementEnd = element["endIndex"] as? Int {
                endIndex = max(endIndex, elementEnd)
            }
            guard let paragraph = element["paragraph"] as? [String: Any],
                  let elements = paragraph["elements"] as? [[String: Any]] else {
                continue
            }
            for el in elements {
                guard let start = el["startIndex"] as? Int,
                      let textRun = el["textRun"] as? [String: Any],
                      let runContent = textRun["content"] as? String else {
                    continue
                }
                var offset = 0
                for unit in runContent.utf16 {
                    units.append(unit)
                    indexMap.append(start + offset)
                    offset += 1
                }
            }
        }
    }

    var anchorIndex: Int?
    let markerUnits = Array(anchorMarker.utf16)
    if !markerUnits.isEmpty, units.count >= markerUnits.count {
        for i in 0...(units.count - markerUnits.count) {
            if Array(units[i ..< i + markerUnits.count]) == markerUnits {
                anchorIndex = indexMap[i]
                break
            }
        }
    }

    return DocumentModel(anchorIndex: anchorIndex, endIndex: endIndex)
}

// MARK: - Google Docs API

private func getDocument(_ documentId: String, token: String) -> [String: Any]? {
    guard let url = URL(string: "https://docs.googleapis.com/v1/documents/\(documentId)") else {
        return nil
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

    guard let (status, data) = synchronousRequest(request) else {
        log("getDocument: no response")
        return nil
    }
    guard status == 200 else {
        log("getDocument: status \(status): \(String(decoding: data, as: UTF8.self))")
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func batchUpdate(_ documentId: String, requests: [[String: Any]], token: String) -> Bool {
    guard let url = URL(string: "https://docs.googleapis.com/v1/documents/\(documentId):batchUpdate"),
          let body = try? JSONSerialization.data(withJSONObject: ["requests": requests]) else {
        return false
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body

    guard let (status, data) = synchronousRequest(request) else {
        log("batchUpdate: no response")
        return false
    }
    guard status == 200 else {
        log("batchUpdate: status \(status): \(String(decoding: data, as: UTF8.self))")
        return false
    }
    return true
}

// MARK: - Google OAuth

private func validAccessToken() -> String? {
    guard let tokens = loadTokens() else { return nil }
    if tokens.expiry > Date().addingTimeInterval(120) {
        return tokens.accessToken
    }
    guard let refreshed = refreshAccessToken(tokens) else {
        log("token refresh failed")
        return nil
    }
    _ = saveTokens(refreshed)
    return refreshed.accessToken
}

private func refreshAccessToken(_ tokens: GoogleTokens) -> GoogleTokens? {
    guard let json = postForm("https://oauth2.googleapis.com/token", [
        "client_id": tokens.clientId,
        "client_secret": tokens.clientSecret,
        "refresh_token": tokens.refreshToken,
        "grant_type": "refresh_token",
    ]), let accessToken = json["access_token"] as? String else {
        return nil
    }
    let expiresIn = (json["expires_in"] as? Double) ?? 3600
    var updated = tokens
    updated.accessToken = accessToken
    updated.expiry = Date().addingTimeInterval(expiresIn)
    return updated
}

private func googleAuth(credentialsPath: String) -> Bool {
    ensureSupportDirectory()

    guard let data = FileManager.default.contents(atPath: credentialsPath),
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
        fputs("Could not read credentials file: \(credentialsPath)\n", stderr)
        return false
    }
    let credentials = (json["installed"] as? [String: Any])
        ?? (json["web"] as? [String: Any])
        ?? json
    guard let clientId = credentials["client_id"] as? String,
          let clientSecret = credentials["client_secret"] as? String else {
        fputs("Credentials file is missing client_id / client_secret.\n", stderr)
        return false
    }

    guard let server = LoopbackServer() else {
        fputs("Could not start the local callback server.\n", stderr)
        return false
    }
    let redirectURI = "http://127.0.0.1:\(server.port)"
    let verifier = base64URL(randomData(32))
    let challenge = base64URL(sha256(Data(verifier.utf8)))

    let authURL = "https://accounts.google.com/o/oauth2/v2/auth?" + queryString([
        "client_id": clientId,
        "redirect_uri": redirectURI,
        "response_type": "code",
        "scope": docsScope,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "access_type": "offline",
        "prompt": "consent",
    ])

    print("Opening Google sign-in in your browser.")
    print("If it does not open, paste this URL into a browser:\n\(authURL)\n")
    if let url = URL(string: authURL) {
        NSWorkspace.shared.open(url)
    }

    let code: String
    switch server.waitForCode() {
    case .success(let value):
        code = value
    case .failure(let message):
        fputs("Authorization failed: \(message)\n", stderr)
        return false
    }

    guard let tokenJSON = postForm("https://oauth2.googleapis.com/token", [
        "code": code,
        "client_id": clientId,
        "client_secret": clientSecret,
        "redirect_uri": redirectURI,
        "grant_type": "authorization_code",
        "code_verifier": verifier,
    ]),
        let accessToken = tokenJSON["access_token"] as? String,
        let refreshToken = tokenJSON["refresh_token"] as? String else {
        fputs("Token exchange failed. See \(logFile.path) for details.\n", stderr)
        return false
    }

    let expiresIn = (tokenJSON["expires_in"] as? Double) ?? 3600
    let tokens = GoogleTokens(
        clientId: clientId,
        clientSecret: clientSecret,
        accessToken: accessToken,
        refreshToken: refreshToken,
        expiry: Date().addingTimeInterval(expiresIn)
    )
    guard saveTokens(tokens) else {
        fputs("Could not save tokens.\n", stderr)
        return false
    }

    print("Connected to Google Docs.")
    return true
}

private func printGoogleAuthHelp() {
    print("""
    Connect Google Docs:

      1. Create a project at https://console.cloud.google.com/
      2. Enable the Google Docs API.
      3. Configure the OAuth consent screen (User type: External; add yourself
         as a test user).
      4. Create an OAuth client ID of type "Desktop app" and download its
         client_secret_*.json file.
      5. Run: CapsDocsCapture --google-auth /path/to/client_secret_*.json

    See DESIGN.md for the full walkthrough.
    """)
}

// MARK: - Loopback HTTP server for the OAuth redirect

private enum AuthCodeResult {
    case success(String)
    case failure(String)
}

private final class LoopbackServer {
    private let socketFD: Int32
    let port: Int

    init?() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                bind(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound, listen(fd, 1) == 0 else {
            close(fd)
            return nil
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer -> Bool in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                getsockname(fd, sockPointer, &length) == 0
            }
        }
        guard named else {
            close(fd)
            return nil
        }

        socketFD = fd
        port = Int(in_port_t(bigEndian: assigned.sin_port))
    }

    func waitForCode() -> AuthCodeResult {
        let client = accept(socketFD, nil, nil)
        guard client >= 0 else {
            return .failure("could not accept the callback connection")
        }
        defer { close(client) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let received = recv(client, &buffer, buffer.count, 0)
        let requestText = received > 0
            ? String(decoding: buffer[0..<received], as: UTF8.self)
            : ""

        let pageBody = "<html><body style=\"font-family:-apple-system,sans-serif\">"
            + "<h2>CapsDocsCapture</h2><p>Authorization received. You can close this tab.</p>"
            + "</body></html>"
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
            + "Content-Length: \(pageBody.utf8.count)\r\nConnection: close\r\n\r\n\(pageBody)"
        let responseBytes = Array(response.utf8)
        _ = responseBytes.withUnsafeBufferPointer { send(client, $0.baseAddress, $0.count, 0) }

        guard let requestLine = requestText.split(separator: "\r\n").first,
              let path = requestLine.split(separator: " ").dropFirst().first,
              let queryStart = path.firstIndex(of: "?") else {
            return .failure("malformed callback request")
        }

        var params: [String: String] = [:]
        for pair in path[path.index(after: queryStart)...].split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let value = String(parts[1])
            params[String(parts[0])] = value.removingPercentEncoding ?? value
        }

        if let error = params["error"] {
            return .failure(error)
        }
        if let code = params["code"] {
            return .success(code)
        }
        return .failure("no authorization code in the callback")
    }

    deinit {
        close(socketFD)
    }
}

// MARK: - HTTP helpers

private func synchronousRequest(_ request: URLRequest) -> (status: Int, data: Data)? {
    let semaphore = DispatchSemaphore(value: 0)
    var output: (Int, Data)?
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        if let http = response as? HTTPURLResponse {
            output = (http.statusCode, data ?? Data())
        } else if let error {
            log("request error: \(error.localizedDescription)")
        }
        semaphore.signal()
    }
    task.resume()
    _ = semaphore.wait(timeout: .now() + 30)
    return output
}

private func postForm(_ urlString: String, _ params: [String: String]) -> [String: Any]? {
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data(queryString(params).utf8)

    guard let (status, data) = synchronousRequest(request) else { return nil }
    let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    if status != 200 {
        log("POST \(urlString): status \(status): \(String(decoding: data, as: UTF8.self))")
        return nil
    }
    return json
}

private func queryString(_ params: [String: String]) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    return params.map { key, value in
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        return "\(encodedKey)=\(encodedValue)"
    }.joined(separator: "&")
}

// MARK: - Crypto helpers

private func randomData(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    for index in 0..<count {
        bytes[index] = UInt8.random(in: 0...255)
    }
    return Data(bytes)
}

private func sha256(_ data: Data) -> Data {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { pointer in
        _ = CC_SHA256(pointer.baseAddress, CC_LONG(data.count), &hash)
    }
    return Data(hash)
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

// MARK: - Daemon

private var daemonAutoQuitTimer: Timer?
private var daemonSignalSources: [DispatchSourceSignal] = []

private func runDaemon() -> Never {
    ensureSupportDirectory()
    log("daemon starting")
    _ = setKarabinerCaptureEnabled(true)
    atexit { _ = setKarabinerCaptureEnabled(false) }

    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    for signalNumber in [SIGINT, SIGTERM] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            log("daemon stopping")
            _ = setKarabinerCaptureEnabled(false)
            exit(0)
        }
        source.resume()
        daemonSignalSources.append(source)
    }

    daemonAutoQuitTimer = Timer.scheduledTimer(withTimeInterval: daemonAutoQuitInterval, repeats: false) { _ in
        log("daemon auto-quit after 1 hour")
        _ = setKarabinerCaptureEnabled(false)
        exit(0)
    }

    log("daemon ready")
    print("\(appName) is running for 1 hour.")
    print("Shift-Caps Lock: set the target Google Doc. Caps Lock: capture selected text into it.")
    app.run()
    fatalError("unreachable")
}

private func stopDaemon() -> Bool {
    let uid = getuid()
    _ = shell("/bin/launchctl bootout gui/\(uid) \(shellQuoted(launchAgentFile.path)) >/dev/null 2>&1 || true")
    _ = setKarabinerCaptureEnabled(false)

    let result = shell("pkill -f 'CapsDocsCapture --daemon' >/dev/null 2>&1 || true")
    if !result.isEmpty {
        print(result)
    }
    return true
}

private func setKarabinerCaptureEnabled(_ enabled: Bool) -> Bool {
    guard FileManager.default.isExecutableFile(atPath: karabinerCLIPath) else {
        log("karabiner cli unavailable")
        return false
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: karabinerCLIPath)
    task.arguments = ["--set-variables", #"{ "\#(karabinerEnabledVariable)": \#(enabled ? 1 : 0) }"#]
    do {
        try task.run()
        task.waitUntilExit()
        let ok = task.terminationStatus == 0
        log("karabiner capture \(enabled ? "enabled" : "disabled"): \(ok ? "ok" : "failed")")
        return ok
    } catch {
        log("karabiner variable failed: \(error)")
        return false
    }
}

private func removeCapsLockMapping() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    task.arguments = ["property", "--set", #"{"UserKeyMapping":[]}"#]
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        fputs("Could not remove Caps Lock mapping: \(error)\n", stderr)
        return false
    }
}

// MARK: - Status

private func status() {
    print("\(appName) status")
    print("Accessibility trusted: \(AXIsProcessTrusted() ? "yes" : "no")")
    print("Support directory: \(supportDirectory.path)")

    if let tokens = loadTokens() {
        let state = tokens.expiry > Date() ? "access token valid" : "access token expired (auto-refreshes)"
        print("Google Docs: connected (\(state))")
    } else {
        print("Google Docs: not connected — run --google-auth <client_secret.json>")
    }

    if let target = loadTarget() {
        print("Target Doc: \(target.title)")
        print("Document ID: \(target.documentId)")
        print("Insert mode: \(target.hasAnchor ? "at saved cursor anchor" : "append to end of document")")
    } else {
        print("Target Doc: none — press Shift-Caps Lock in a Google Doc")
    }

    let daemonRunning = !shell("pgrep -f '/CapsDocsCapture --daemon' 2>/dev/null || true")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    print("Daemon running: \(daemonRunning ? "yes" : "no")")
    print("Karabiner CLI: \(FileManager.default.isExecutableFile(atPath: karabinerCLIPath) ? "found" : "not found")")
    print("Log file: \(logFile.path)")
}

private func requestAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    print("Accessibility trusted: \(AXIsProcessTrustedWithOptions(options) ? "yes" : "not yet")")
}

// MARK: - Persistence

private func loadTarget() -> Target? {
    guard let data = try? Data(contentsOf: targetFile) else { return nil }
    return try? jsonDecoder().decode(Target.self, from: data)
}

private func saveTarget(_ target: Target) -> Bool {
    ensureSupportDirectory()
    do {
        try jsonEncoder().encode(target).write(to: targetFile, options: .atomic)
        log("saved target: \(target.title) (\(target.hasAnchor ? "anchor" : "append"))")
        return true
    } catch {
        log("target save error: \(error)")
        return false
    }
}

private func loadTokens() -> GoogleTokens? {
    guard let data = try? Data(contentsOf: tokenFile) else { return nil }
    return try? jsonDecoder().decode(GoogleTokens.self, from: data)
}

private func saveTokens(_ tokens: GoogleTokens) -> Bool {
    ensureSupportDirectory()
    do {
        try jsonEncoder().encode(tokens).write(to: tokenFile, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        return true
    } catch {
        log("token save error: \(error)")
        return false
    }
}

private func jsonEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func jsonDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}

// MARK: - Keyboard

private func keyCombo(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }

    if flags.contains(.maskCommand) {
        CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: true)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.015)
    }

    let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
    down?.flags = flags
    down?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.015)

    let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
    up?.flags = flags
    up?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.015)

    if flags.contains(.maskCommand) {
        CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: false)?
            .post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.015)
    }
}

// MARK: - System helpers

private func shell(_ command: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-lc", command]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return "\(error)"
    }
}

private func shellQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func ensureSupportDirectory() {
    try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
}

private func notify(title: String, body: String) {
    let notification = NSUserNotification()
    notification.title = title
    notification.informativeText = body
    NSUserNotificationCenter.default.deliver(notification)
}

private func log(_ message: String) {
    ensureSupportDirectory()
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }

    if FileManager.default.fileExists(atPath: logFile.path),
       let handle = try? FileHandle(forWritingTo: logFile) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    } else {
        try? data.write(to: logFile)
    }
}

// MARK: - CLI

private func usage() {
    print("""
    Usage:
      CapsDocsCapture --daemon                 Enable hotkeys for 1 hour
      CapsDocsCapture --stop                   Disable hotkeys and stop the daemon
      CapsDocsCapture --google-auth FILE       Connect Google Docs (FILE = client_secret.json)
      CapsDocsCapture --set-target             Save the focused Google Doc as the target
      CapsDocsCapture --set-target-url TEXT    Save a Doc by URL or document ID (append-to-end)
      CapsDocsCapture --once                   Capture selected text into the target Doc
      CapsDocsCapture --status                 Show current configuration
      CapsDocsCapture --request-accessibility  Prompt for Accessibility permission
      CapsDocsCapture --unmap-capslock         Remove any legacy Caps Lock key mapping
    """)
}

private let rawArguments = Array(CommandLine.arguments.dropFirst())
private let flags = Set(rawArguments)

private func argumentValue(after flag: String) -> String? {
    guard let index = rawArguments.firstIndex(of: flag),
          rawArguments.indices.contains(index + 1) else {
        return nil
    }
    return rawArguments[index + 1]
}

if flags.contains("--daemon") {
    runDaemon()
} else if flags.contains("--stop") {
    exit(stopDaemon() ? 0 : 1)
} else if flags.contains("--once") {
    exit(captureOnce() ? 0 : 1)
} else if flags.contains("--set-target") {
    exit(setTargetFromFrontTab() ? 0 : 1)
} else if flags.contains("--set-target-url") {
    guard let value = argumentValue(after: "--set-target-url") else {
        fputs("--set-target-url needs a Google Doc URL or document ID\n", stderr)
        exit(1)
    }
    exit(setTargetByURL(value) ? 0 : 1)
} else if flags.contains("--google-auth") {
    guard let path = argumentValue(after: "--google-auth") else {
        printGoogleAuthHelp()
        exit(1)
    }
    exit(googleAuth(credentialsPath: path) ? 0 : 1)
} else if flags.contains("--status") {
    status()
} else if flags.contains("--request-accessibility") {
    requestAccessibility()
} else if flags.contains("--unmap-capslock") {
    exit(removeCapsLockMapping() ? 0 : 1)
} else {
    usage()
}
