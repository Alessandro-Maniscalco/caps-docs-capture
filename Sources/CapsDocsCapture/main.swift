import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import IOKit.hid

private let appName = "CapsDocsCapture"
private let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".caps-docs-capture", isDirectory: true)
private let targetFile = supportDirectory.appendingPathComponent("target.json")
private let logFile = supportDirectory.appendingPathComponent("capture.log")
private let karabinerLogFile = supportDirectory.appendingPathComponent("karabiner.log")
private let launchAgentFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/com.alessandro.CapsDocsCapture.plist")
private let triggerNotificationName = Notification.Name("com.alessandro.CapsDocsCapture.trigger")
private let karabinerCLIPath = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
private let karabinerEnabledVariable = "caps_docs_capture_enabled"
private let daemonAutoQuitInterval: TimeInterval = 60 * 60

private let keyCodeC: CGKeyCode = 8
private let keyCodeV: CGKeyCode = 9
private let keyCodeCommand: CGKeyCode = 55
private let keyCodeF18: CGKeyCode = 79
private let keyCodeCapsLock: CGKeyCode = 57
private let eventTypeSystemDefinedRawValue: UInt32 = 14
private let hidUsagePageKeyboardOrKeypad: UInt32 = 0x07
private let hidUsageKeyboardCapsLock: UInt32 = 0x39

private let chromiumBrowserNames = [
    "ChatGPT Atlas",
    "Google Chrome",
    "Brave Browser",
    "Microsoft Edge",
    "Arc",
]

private struct TargetDocument: Codable {
    var appName: String
    var bundleIdentifier: String?
    var windowID: Int
    var tabIndex: Int
    var title: String
    var url: String
    var bounds: WindowBounds?
    var focusPoint: TargetFocusPoint?
    var createdAt: Date
}

private struct BrowserWindowInfo {
    var appName: String
    var bundleIdentifier: String?
    var windowID: Int
    var tabIndex: Int
    var title: String
    var url: String
    var bounds: WindowBounds?
}

private extension TargetDocument {
    var browserWindowInfo: BrowserWindowInfo {
        BrowserWindowInfo(
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            windowID: windowID,
            tabIndex: tabIndex,
            title: title,
            url: url,
            bounds: bounds
        )
    }
}

private struct OnScreenWindow {
    var ownerName: String
    var title: String
    var bounds: WindowBounds
}

private struct FocusedTarget {
    var info: BrowserWindowInfo
    var focusPoint: TargetFocusPoint?
}

private struct WindowBounds: Codable {
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double

    func contains(_ point: CGPoint, tolerance: Double = 20) -> Bool {
        point.x >= left - tolerance &&
            point.x <= right + tolerance &&
            point.y >= top - tolerance &&
            point.y <= bottom + tolerance
    }

    var width: Double { max(1, right - left) }
    var height: Double { max(1, bottom - top) }

    var documentBodyTop: Double {
        top + min(260, max(140, height * 0.20))
    }
}

private struct TargetFocusPoint: Codable {
    var x: Double
    var y: Double
    var relativeX: Double
    var relativeY: Double
}

private enum TargetSearchMode {
    case url
    case title
}

private struct SourceWindow {
    var appName: String
    var bundleIdentifier: String?
    var processIdentifier: pid_t?
    var windowID: Int?
}

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

        let items = itemData.map { values in
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

private final class CaptureController {
    private var isCapturing = false
    private var captureScheduled = false
    private var scheduledSourceProcessIdentifier: pid_t?
    private var lastTrigger = Date.distantPast
    private var eventMonitors: [Any] = []
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private var hidManager: IOHIDManager?
    private var distributedObservers: [NSObjectProtocol] = []
    private var signalSources: [DispatchSourceSignal] = []
    private var targetRefreshTimer: Timer?
    private var autoQuitTimer: Timer?
    private var lastTrackedTargetKey: String?

    func runDaemon() -> Never {
        ensureSupportDirectory()
        log("daemon starting")
        _ = setKarabinerCaptureEnabled(true)
        atexit {
            _ = setKarabinerCaptureEnabled(false)
            _ = removeCapsLockMapping()
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        _ = installEventTap()
        _ = installHIDMonitor()
        installTriggerNotificationObserver()
        installSignalTrigger()
        installTerminationCleanup()
        installFocusedTargetTracker()
        installAutoQuitTimer()

        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == UInt16(keyCodeF18) {
                self?.triggerCapture()
            }
        }) {
            eventMonitors.append(monitor)
        }

        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == UInt16(keyCodeF18) {
                self?.triggerCapture()
                return nil
            }
            return event
        }) {
            eventMonitors.append(monitor)
        }

        print("\(appName) is running for 1 hour. Press Caps Lock to capture selected text into Google Docs.")
        app.run()
        fatalError("unreachable")
    }

    private func installFocusedTargetTracker() {
        targetRefreshTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.refreshFocusedDocsTarget()
        }
        log("focused target tracker installed")
    }

    private func installAutoQuitTimer() {
        autoQuitTimer = Timer.scheduledTimer(withTimeInterval: daemonAutoQuitInterval, repeats: false) { _ in
            log("daemon auto-quit after 1 hour")
            _ = setKarabinerCaptureEnabled(false)
            _ = removeCapsLockMapping()
            exit(0)
        }
        log("auto-quit timer installed for 1 hour")
    }

    private func refreshFocusedDocsTarget() {
        guard !isCapturing,
              loadTarget() == nil,
              let info = currentOnScreenGoogleDocsWindow() else {
            return
        }

        let key = "\(info.appName)|\(info.windowID)|\(info.tabIndex)|\(info.url)"
        guard key != lastTrackedTargetKey else { return }

        let target = TargetDocument(
            appName: info.appName,
            bundleIdentifier: info.bundleIdentifier,
            windowID: info.windowID,
            tabIndex: info.tabIndex,
            title: info.title,
            url: info.url,
            bounds: info.bounds,
            focusPoint: nil,
            createdAt: Date()
        )

        if saveTarget(target) {
            lastTrackedTargetKey = key
            log("tracked target: \(info.title)")
        }
    }

    private func installEventTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) |
            CGEventMask(1 << CGEventType.flagsChanged.rawValue) |
            CGEventMask(1 << eventTypeSystemDefinedRawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: captureEventTapCallback,
            userInfo: userInfo
        ) else {
            log("event tap unavailable; check Input Monitoring")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        eventTapRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("event tap installed")
        return true
    }

    private func installHIDMonitor() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let keyboardMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        let keypadMatch: [String: Any] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad,
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, [keyboardMatch, keypadMatch] as CFArray)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, captureHIDValueCallback, userInfo)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            log("hid monitor unavailable: \(result)")
            return false
        }

        hidManager = manager
        log("hid monitor installed")
        return true
    }

    private func installTriggerNotificationObserver() {
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: triggerNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.triggerCapture()
        }
        distributedObservers.append(observer)
        log("trigger notification installed")
    }

    private func installSignalTrigger() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in
            self?.triggerCapture()
        }
        source.resume()
        signalSources.append(source)
        log("signal trigger installed")
    }

    private func installTerminationCleanup() {
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                log("daemon stopping")
                _ = setKarabinerCaptureEnabled(false)
                _ = removeCapsLockMapping()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
        log("termination cleanup installed")
    }

    fileprivate func handleEventTap(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                log("event tap re-enabled")
            }
            return
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown, keyCode == keyCodeF18 {
            log("event tap F18")
            triggerCapture(sourceProcessIdentifier: eventTargetProcessIdentifier(event))
        } else if type == .flagsChanged, keyCode == keyCodeCapsLock {
            log("event tap caps lock")
            triggerCapture(sourceProcessIdentifier: eventTargetProcessIdentifier(event))
        }
    }

    fileprivate func handleHIDValue(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        let usagePage = IOHIDElementGetUsagePage(element)
        let usage = IOHIDElementGetUsage(element)
        let pressed = IOHIDValueGetIntegerValue(value) != 0

        guard pressed, usagePage == hidUsagePageKeyboardOrKeypad else { return }

        if usage == hidUsageKeyboardCapsLock {
            log("hid caps lock")
            triggerCapture()
        }
    }

    func captureOnce(sourceProcessIdentifier: pid_t? = nil) -> Bool {
        if isCapturing { return false }
        isCapturing = true
        defer { isCapturing = false }

        log("capture begin")
        let source = currentSourceWindow(processIdentifier: sourceProcessIdentifier)
        log("source app: \(source.appName.isEmpty ? "(unknown)" : source.appName)")
        let snapshot = PasteboardSnapshot()

        guard let text = readSelectedTextFromFocusedElement(source: source) ?? copySelectedText(),
              !text.isEmpty else {
            snapshot.restore()
            log("nothing copied")
            NSSound.beep()
            return false
        }
        log("copied \(text.count) chars")

        guard let target = focusTargetDocument() else {
            snapshot.restore()
            log("no docs target available")
            notify(title: "No Google Docs target", body: "Open your notes Doc or run --set-target while it is focused.")
            return false
        }
        log("target focused")
        log("front app after target focus: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "(unknown)")")

        Thread.sleep(forTimeInterval: 0.18)
        let textToPaste = text.hasSuffix("\n") ? text : text + "\n"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textToPaste, forType: .string)
        clickTargetFocusPoint(target.focusPoint, bounds: matchingOnScreenWindow(for: target.info)?.bounds ?? target.info.bounds)
        keyCombo(keyCodeV, flags: .maskCommand)
        log("paste command sent via CGEvent")
        Thread.sleep(forTimeInterval: 2.2)
        snapshot.restore()
        returnToSource(source)
        log("captured \(text.count) chars")
        return true
    }

    private func triggerCapture(sourceProcessIdentifier: pid_t? = nil) {
        let now = Date()
        guard !isCapturing, !captureScheduled else { return }

        if now.timeIntervalSince(lastTrigger) > 0.35 {
            lastTrigger = now
            log("hotkey")
            captureScheduled = true
            scheduledSourceProcessIdentifier = sourceProcessIdentifier
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let sourceProcessIdentifier = self.scheduledSourceProcessIdentifier
                self.scheduledSourceProcessIdentifier = nil
                self.captureScheduled = false
                _ = self.captureOnce(sourceProcessIdentifier: sourceProcessIdentifier)
            }
        }
    }
}

private func captureHIDValueCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    guard let context else { return }
    let controller = Unmanaged<CaptureController>.fromOpaque(context).takeUnretainedValue()
    controller.handleHIDValue(value)
}

private func captureEventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let controller = Unmanaged<CaptureController>.fromOpaque(refcon).takeUnretainedValue()
        controller.handleEventTap(type: type, event: event)
    }

    return Unmanaged.passUnretained(event)
}

private func eventTargetProcessIdentifier(_ event: CGEvent) -> pid_t? {
    let processIdentifier = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
    return processIdentifier > 0 ? processIdentifier : nil
}

private func triggerDaemon() {
    DistributedNotificationCenter.default().postNotificationName(
        triggerNotificationName,
        object: nil,
        userInfo: nil,
        deliverImmediately: true
    )
}

private func setTargetToFrontDocument() -> Bool {
    ensureSupportDirectory()

    if let info = currentBrowserWindowInfo(), isGoogleDocumentURL(info.url) {
        return saveTarget(info)
    }
    if let info = currentMouseGoogleDocsWindow(requireSupportedFrontApp: true) {
        return saveTarget(info)
    }
    if let info = currentAccessibilityGoogleDocsWindow() {
        return saveTarget(info)
    }

    fputs("Click the target Google Docs window now. Waiting up to 5 seconds...\n", stderr)
    let deadline = Date().addingTimeInterval(5.0)
    while Date() < deadline {
        if let info = currentBrowserWindowInfo(), isGoogleDocumentURL(info.url) {
            return saveTarget(info)
        }
        if let info = currentMouseGoogleDocsWindow(requireSupportedFrontApp: false) {
            return saveTarget(info)
        }
        if let info = currentAccessibilityGoogleDocsWindow() {
            return saveTarget(info)
        }
        Thread.sleep(forTimeInterval: 0.1)
    }

    if let info = currentOnScreenGoogleDocsWindow() {
        return saveTarget(info)
    }

    if let info = currentBrowserWindowInfo() {
        fputs("The focused browser tab is not a Google Docs document.\n", stderr)
        fputs("Focused URL: \(info.url)\n", stderr)
        log("set target failed: focused browser tab is not Google Docs: \(info.url)")
    } else {
        fputs("No focused or visible Google Docs window found in a supported browser.\n", stderr)
        log("set target failed: no focused or visible Google Docs window")
    }
    return false
}

private func saveTarget(_ info: BrowserWindowInfo) -> Bool {
    let target = TargetDocument(
        appName: info.appName,
        bundleIdentifier: info.bundleIdentifier,
        windowID: info.windowID,
        tabIndex: info.tabIndex,
        title: info.title,
        url: info.url,
        bounds: info.bounds,
        focusPoint: currentMouseTargetFocusPoint(bounds: info.bounds),
        createdAt: Date()
    )

    if saveTarget(target) {
        print("Saved target Doc: \(target.title)")
        print(target.url)
        return true
    }

    fputs("Could not save target.\n", stderr)
    return false
}

private func setTargetBySearch(_ query: String, mode: TargetSearchMode) -> Bool {
    ensureSupportDirectory()

    for browser in chromiumBrowserNames where isAppRunning(appName: browser) {
        for info in allBrowserTabs(appName: browser) {
            guard isGoogleDocumentURL(info.url) else { continue }

            let haystack = mode == .url ? info.url : info.title
            if haystack.localizedCaseInsensitiveContains(query) {
                let target = TargetDocument(
                    appName: info.appName,
                    bundleIdentifier: info.bundleIdentifier,
                    windowID: info.windowID,
                    tabIndex: info.tabIndex,
                    title: info.title,
                    url: info.url,
                    bounds: info.bounds,
                    focusPoint: nil,
                    createdAt: Date()
                )

                if saveTarget(target) {
                    print("Saved target Doc: \(target.title)")
                    print(target.url)
                    return true
                }

                fputs("Could not save target.\n", stderr)
                return false
            }
        }
    }

    fputs("No matching Google Docs document found for query: \(query)\n", stderr)
    log("set target failed: no match for \(mode == .url ? "url" : "title") query \(query)")
    return false
}

private func listGoogleDocuments() {
    for browser in chromiumBrowserNames where isAppRunning(appName: browser) {
        for info in allBrowserTabs(appName: browser) where isGoogleDocumentURL(info.url) {
            print("\(info.appName) window=\(info.windowID) tab=\(info.tabIndex)")
            print("  \(info.title)")
            print("  \(info.url)")
        }
    }
}

private func status() {
    print("\(appName) status")
    print("Accessibility trusted: \(AXIsProcessTrusted() ? "yes" : "no")")
    if #available(macOS 10.15, *) {
        print("Input Monitoring trusted: \(CGPreflightListenEventAccess() ? "yes" : "no")")
    }
    print("Support directory: \(supportDirectory.path)")

    if let target = loadTarget() {
        print("Target: \(target.title)")
        print("Target app: \(target.appName)")
        print("Target URL: \(target.url)")
        print("Target body click point: \(target.focusPoint == nil ? "not saved" : "saved")")
    } else {
        print("Target: none saved; first open Google Doc will be used")
    }

    let daemonPIDs = shell("pgrep -f '/CapsDocsCapture --daemon' 2>/dev/null || true")
        .split(whereSeparator: \.isNewline)
        .map(String.init)
    print("Daemon running: \(daemonPIDs.isEmpty ? "no" : "yes (pid \(daemonPIDs.joined(separator: ", ")))")")
    print("Karabiner CLI: \(FileManager.default.isExecutableFile(atPath: karabinerCLIPath) ? "yes" : "not found")")
    print("Capture log: \(logFile.path)")
    print("Karabiner event log: \(karabinerLogFile.path)")

    let mapping = shell("/usr/bin/hidutil property --get UserKeyMapping")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if !mapping.isEmpty, mapping != "(\n)" {
        print("Legacy hidutil Caps Lock mapping:")
        print(mapping)
    }
}

private func requestAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(options)
    print("Accessibility trusted: \(trusted ? "yes" : "not yet")")
}

private func applyCapsLockMapping() -> Bool {
    let json = #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771181}]}"#
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    task.arguments = ["property", "--set", json]

    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        fputs("Could not apply Caps Lock mapping: \(error)\n", stderr)
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

private func stopDaemon() -> Bool {
    let uid = getuid()
    _ = shell("/bin/launchctl bootout gui/\(uid) \(shellQuoted(launchAgentFile.path)) >/dev/null 2>&1 || true")
    _ = setKarabinerCaptureEnabled(false)

    let result = shell("""
    pkill -f 'CapsDocsCapture --daemon' >/dev/null 2>&1 || true
    pkill -f '/usr/bin/open -W -g .*/CapsDocsCapture[.]app' >/dev/null 2>&1 || true
    """)
    if !result.isEmpty {
        print(result)
    }
    return removeCapsLockMapping()
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

private func currentSourceWindow(processIdentifier: pid_t? = nil) -> SourceWindow {
    if let processIdentifier,
       let app = NSRunningApplication(processIdentifier: processIdentifier) {
        return SourceWindow(
            appName: app.localizedName ?? "",
            bundleIdentifier: app.bundleIdentifier,
            processIdentifier: app.processIdentifier,
            windowID: nil
        )
    }

    let frontApp = NSWorkspace.shared.frontmostApplication
    let appName = frontApp?.localizedName ?? ""
    let bundleID = frontApp?.bundleIdentifier
    return SourceWindow(
        appName: appName,
        bundleIdentifier: bundleID,
        processIdentifier: frontApp?.processIdentifier,
        windowID: nil
    )
}

private func currentBrowserWindowInfo() -> BrowserWindowInfo? {
    let frontApp = NSWorkspace.shared.frontmostApplication
    guard let appName = frontApp?.localizedName else { return nil }
    return currentBrowserWindowInfo(appName: appName, bundleIdentifier: frontApp?.bundleIdentifier)
}

private func currentAccessibilityGoogleDocsWindow() -> BrowserWindowInfo? {
    guard let frontApp = NSWorkspace.shared.frontmostApplication,
          let appName = frontApp.localizedName,
          chromiumBrowserNames.contains(appName),
          let title = accessibilityWindowTitle(app: frontApp),
          title.localizedCaseInsensitiveContains("Google Docs") else {
        return nil
    }

    return googleDocsTabMatchingTitle(title, appName: appName)
}

private func googleDocsTabMatchingTitle(_ title: String, appName: String) -> BrowserWindowInfo? {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let docsTabs = allBrowserTabs(appName: appName).filter { isGoogleDocumentURL($0.url) }

    return docsTabs.first { $0.title == normalizedTitle } ??
        docsTabs.first {
            $0.title.localizedCaseInsensitiveContains(normalizedTitle) ||
                normalizedTitle.localizedCaseInsensitiveContains($0.title)
        }
}

private func accessibilityWindowTitle(app: NSRunningApplication) -> String? {
    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
        var windowValue: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(axApp, attribute as CFString, &windowValue)
        guard windowError == .success, let windowValue else { continue }

        let window = windowValue as! AXUIElement
        var titleValue: CFTypeRef?
        let titleError = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
        guard titleError == .success, let title = titleValue as? String, !title.isEmpty else {
            continue
        }
        return title
    }

    return nil
}

private func currentBrowserWindowInfo(appName: String, bundleIdentifier: String?) -> BrowserWindowInfo? {
    guard chromiumBrowserNames.contains(appName) else { return nil }

    let script = """
    tell application "\(appleScriptEscaped(appName))"
      set w to front window
      if visible of w is false then return ""
      set tabNumber to active tab index of w
      set t to active tab of w
      set b to bounds of w
      return (id of w as text) & linefeed & (tabNumber as text) & linefeed & (title of t as text) & linefeed & (URL of t as text) & linefeed & (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text)
    end tell
    """

    guard let output = runAppleScript(script) else { return nil }
    let lines = output.components(separatedBy: "\n")
    guard lines.count >= 4, let windowID = Int(lines[0]), let tabIndex = Int(lines[1]) else {
        return nil
    }

    return BrowserWindowInfo(
        appName: appName,
        bundleIdentifier: bundleIdentifier,
        windowID: windowID,
        tabIndex: tabIndex,
        title: lines[2],
        url: lines[3],
        bounds: lines.count >= 5 ? parseBounds(lines[4]) : nil
    )
}

private func activeBrowserTabs(appName: String) -> [BrowserWindowInfo] {
    guard chromiumBrowserNames.contains(appName) else { return [] }

    let script = """
    set fieldDelimiter to ASCII character 9
    set output to ""
    tell application "\(appleScriptEscaped(appName))"
      repeat with w in windows
        try
          set tabNumber to active tab index of w
          set t to active tab of w
          set b to bounds of w
          set boundsText to (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text)
          set output to output & (id of w as text) & fieldDelimiter & (tabNumber as text) & fieldDelimiter & (title of t as text) & fieldDelimiter & (URL of t as text) & fieldDelimiter & boundsText & linefeed
        end try
      end repeat
    end tell
    return output
    """

    guard let output = runAppleScript(script) else { return [] }

    return output.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4,
              let windowID = Int(parts[0]),
              let tabIndex = Int(parts[1]) else {
            return nil
        }

        let bundleID = NSWorkspace.shared.runningApplications
            .first { $0.localizedName == appName && $0.activationPolicy == .regular }?
            .bundleIdentifier ?? NSWorkspace.shared.runningApplications
            .first { $0.localizedName == appName }?
            .bundleIdentifier

        return BrowserWindowInfo(
            appName: appName,
            bundleIdentifier: bundleID,
            windowID: windowID,
            tabIndex: tabIndex,
            title: String(parts[2]),
            url: String(parts[3]),
            bounds: parts.count >= 5 ? parseBounds(String(parts[4])) : nil
        )
    }
}

private func currentMouseGoogleDocsWindow(requireSupportedFrontApp: Bool) -> BrowserWindowInfo? {
    var appNames = chromiumBrowserNames.filter(isAppRunning(appName:))
    if requireSupportedFrontApp {
        guard let frontAppName = NSWorkspace.shared.frontmostApplication?.localizedName,
              chromiumBrowserNames.contains(frontAppName) else {
            return nil
        }
        appNames = [frontAppName]
    }
    guard let mouseEvent = CGEvent(source: nil) else { return nil }
    let point = mouseEvent.location

    let matches = appNames
        .flatMap(activeBrowserTabs(appName:))
        .filter { isGoogleDocumentURL($0.url) }
        .filter { browserWindowContains($0.bounds, point: point) }

    return matches.min { lhs, rhs in
        browserWindowArea(lhs.bounds) < browserWindowArea(rhs.bounds)
    }
}

private func browserWindowContains(_ bounds: WindowBounds?, point: CGPoint) -> Bool {
    guard let bounds else { return false }
    let horizontalTolerance = 40.0
    let topTolerance = 180.0
    let bottomTolerance = 40.0

    return point.x >= bounds.left - horizontalTolerance &&
        point.x <= bounds.right + horizontalTolerance &&
        point.y >= max(0, bounds.top - topTolerance) &&
        point.y <= bounds.bottom + bottomTolerance
}

private func browserWindowArea(_ bounds: WindowBounds?) -> Double {
    guard let bounds else { return Double.greatestFiniteMagnitude }
    return max(1, bounds.right - bounds.left) * max(1, bounds.bottom - bounds.top)
}

private func allBrowserTabs(appName: String) -> [BrowserWindowInfo] {
    guard chromiumBrowserNames.contains(appName) else { return [] }

    let script = """
    set fieldDelimiter to ASCII character 9
    set output to ""
    tell application "\(appleScriptEscaped(appName))"
      repeat with w in windows
        set tabCount to count of tabs of w
        repeat with i from 1 to tabCount
          set t to tab i of w
          set b to bounds of w
          set boundsText to (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text)
          set output to output & (id of w as text) & fieldDelimiter & (i as text) & fieldDelimiter & (title of t as text) & fieldDelimiter & (URL of t as text) & fieldDelimiter & boundsText & linefeed
        end repeat
      end repeat
    end tell
    return output
    """

    guard let output = runAppleScript(script) else { return [] }

    return output.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 4,
              let windowID = Int(parts[0]),
              let tabIndex = Int(parts[1]) else {
            return nil
        }

        let bundleID = NSWorkspace.shared.runningApplications
            .first { $0.localizedName == appName }?
            .bundleIdentifier

        return BrowserWindowInfo(
            appName: appName,
            bundleIdentifier: bundleID,
            windowID: windowID,
            tabIndex: tabIndex,
            title: String(parts[2]),
            url: String(parts[3]),
            bounds: parts.count >= 5 ? parseBounds(String(parts[4])) : nil
        )
    }
}

private func copySelectedText(timeout: TimeInterval = 1.0) -> String? {
    let pasteboard = NSPasteboard.general
    let sentinel = "__CAPS_DOCS_CAPTURE_\(UUID().uuidString)__"
    pasteboard.clearContents()
    pasteboard.setString(sentinel, forType: .string)
    let startChangeCount = pasteboard.changeCount

    func copiedValue(until deadline: Date) -> String? {
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
            let value = pasteboard.string(forType: .string)
            if pasteboard.changeCount != startChangeCount, value != sentinel {
                return value
            }
        }
        return nil
    }

    keyCombo(keyCodeC, flags: .maskCommand)
    if let value = copiedValue(until: Date().addingTimeInterval(timeout)) {
        return value
    }

    if systemEventsKeystroke("c", usingCommand: true),
       let value = copiedValue(until: Date().addingTimeInterval(timeout)) {
        return value
    }

    let fallback = pasteboard.string(forType: .string)
    return fallback == sentinel ? nil : fallback
}

private func readSelectedTextFromFocusedElement(source: SourceWindow) -> String? {
    guard let app = source.processIdentifier.flatMap({ processIdentifier in
        NSRunningApplication(processIdentifier: processIdentifier)
    }) ?? source.bundleIdentifier.flatMap({ bundleIdentifier in
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }) ?? NSWorkspace.shared.frontmostApplication else {
        log("ax selected text: no source app")
        return nil
    }

    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var focusedValue: CFTypeRef?
    let focusedError = AXUIElementCopyAttributeValue(
        axApp,
        kAXFocusedUIElementAttribute as CFString,
        &focusedValue
    )
    guard focusedError == .success, let focusedValue else {
        log("ax selected text: focused error \(focusedError.rawValue) for \(app.localizedName ?? "unknown")")
        return nil
    }

    let focusedElement = focusedValue as! AXUIElement
    var selectedValue: CFTypeRef?
    let selectedError = AXUIElementCopyAttributeValue(
        focusedElement,
        kAXSelectedTextAttribute as CFString,
        &selectedValue
    )
    guard selectedError == .success else {
        log("ax selected text: selected error \(selectedError.rawValue) for \(app.localizedName ?? "unknown")")
        return nil
    }

    guard let text = selectedValue as? String else {
        log("ax selected text: non-string selected value for \(app.localizedName ?? "unknown")")
        return nil
    }
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized.isEmpty {
        log("ax selected text: empty selection for \(app.localizedName ?? "unknown")")
        return nil
    }
    log("ax selected text: read \(text.count) chars from \(app.localizedName ?? "unknown")")
    return text
}

private func focusTargetDocument() -> FocusedTarget? {
    if let target = loadTarget() {
        log("target candidate: \(target.title) window=\(target.windowID) tab=\(target.tabIndex)")
        if let focused = focusSavedTarget(target) {
            return focused
        }
        log("saved target focus failed")
    }

    for browser in chromiumBrowserNames {
        if let focused = focusFirstGoogleDocsWindow(appName: browser) {
            log("focused fallback docs window in \(browser)")
            return focused
        }
    }

    return nil
}

private func focusSavedTarget(_ target: TargetDocument) -> FocusedTarget? {
    if focusBrowserTab(target.browserWindowInfo) {
        return FocusedTarget(info: target.browserWindowInfo, focusPoint: target.focusPoint)
    }

    if matchingOnScreenWindow(for: target) != nil {
        _ = bringProcessToFront(appName: target.appName)
        _ = raiseProcessWindow(appName: target.appName)
        _ = shell("/usr/bin/open -a \(shellQuoted(target.appName))")
        Thread.sleep(forTimeInterval: 0.35)
        return waitForKeyboardFocus(appName: target.appName)
            ? FocusedTarget(info: target.browserWindowInfo, focusPoint: target.focusPoint)
            : nil
    }

    if let currentInfo = findOpenTab(url: target.url, appName: target.appName) {
        return focusBrowserTab(currentInfo) ? FocusedTarget(info: currentInfo, focusPoint: target.focusPoint) : nil
    }

    return nil
}

private func findOpenTab(url: String, appName: String) -> BrowserWindowInfo? {
    let targetDocumentId = googleDocumentID(url)
    let matches = allBrowserTabs(appName: appName).filter { info in
        if info.url == url { return true }
        if let targetDocumentId {
            return googleDocumentID(info.url) == targetDocumentId
        }
        return false
    }
    if let exactMatch = matches.first(where: { $0.url == url }) {
        return exactMatch
    }
    return matches.first
}

private func googleDocumentID(_ url: String) -> String? {
    guard let range = url.range(of: "/document/d/") else { return nil }
    let afterPrefix = url[range.upperBound...]
    let id = afterPrefix.split(separator: "/").first.map(String.init)
    return id?.isEmpty == false ? id : nil
}

private func focusFirstGoogleDocsWindow(appName: String) -> FocusedTarget? {
    if onScreenWindows(appName: appName)
        .contains(where: { $0.title.localizedCaseInsensitiveContains("Google Docs") }) {
        _ = bringProcessToFront(appName: appName)
        _ = raiseProcessWindow(appName: appName)
        _ = shell("/usr/bin/open -a \(shellQuoted(appName))")
        Thread.sleep(forTimeInterval: 0.35)
        if waitForKeyboardFocus(appName: appName),
           let info = topOnScreenGoogleDocsWindow(appName: appName) {
            return FocusedTarget(info: info, focusPoint: nil)
        }
    }

    if let info = topOnScreenGoogleDocsWindow(appName: appName) {
        return focusBrowserTab(info) ? FocusedTarget(info: info, focusPoint: nil) : nil
    }

    return nil
}

private func currentOnScreenGoogleDocsWindow() -> BrowserWindowInfo? {
    for browser in chromiumBrowserNames where isAppRunning(appName: browser) {
        if let info = topOnScreenGoogleDocsWindow(appName: browser) {
            return info
        }
    }
    return nil
}

private func topOnScreenGoogleDocsWindow(appName: String) -> BrowserWindowInfo? {
    let visibleDocsWindows = onScreenWindows(appName: appName)
        .filter { $0.title.localizedCaseInsensitiveContains("Google Docs") }
    guard !visibleDocsWindows.isEmpty else { return nil }

    let docsTabs = allBrowserTabs(appName: appName)
        .filter { isGoogleDocumentURL($0.url) }

    for window in visibleDocsWindows {
        if let match = docsTabs.first(where: { info in
            info.title == window.title && browserBoundsMatch(info.bounds, window.bounds)
        }) {
            return match
        }

        if let match = docsTabs.first(where: { $0.title == window.title }) {
            return match
        }
    }

    return nil
}

private func focusBrowserTab(_ info: BrowserWindowInfo) -> Bool {
    let result = runAppleScript("""
    tell application "\(appleScriptEscaped(info.appName))"
      try
        set w to window id \(info.windowID)
        set active tab index of w to \(info.tabIndex)
        set index of w to 1
        activate
        return "ok"
      end try
    end tell
    return "missing"
    """)

    guard result?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" else {
        log("target tab script failed: \(result ?? "nil")")
        return false
    }

    guard activateApp(appName: info.appName, bundleIdentifier: info.bundleIdentifier) else {
        log("target activate failed: \(info.appName)")
        return false
    }

    _ = raiseProcessWindow(appName: info.appName)
    _ = shell("/usr/bin/open -a \(shellQuoted(info.appName))")
    let front = waitForKeyboardFocus(appName: info.appName)
    log("target front check: \(front ? "ok" : "failed") ns=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "(none)") se=\(systemEventsFrontmostProcessName() ?? "(none)")")
    return front
}

private func isBrowserWindowOnScreen(_ info: BrowserWindowInfo) -> Bool {
    matchingOnScreenWindow(for: info) != nil
}

private func matchingOnScreenWindow(for info: BrowserWindowInfo) -> OnScreenWindow? {
    onScreenWindows(appName: info.appName).first { window in
        window.title == info.title && browserBoundsMatch(info.bounds, window.bounds)
    }
}

private func matchingOnScreenWindow(for target: TargetDocument) -> OnScreenWindow? {
    onScreenWindows(appName: target.appName).first { window in
        window.title == target.title && browserBoundsMatch(target.bounds, window.bounds)
    }
}

private func browserBoundsMatch(_ browserBounds: WindowBounds?, _ screenBounds: WindowBounds) -> Bool {
    guard let browserBounds else { return true }
    return abs(browserBounds.left - screenBounds.left) < 80 &&
        abs(browserBounds.right - screenBounds.right) < 80 &&
        abs(browserBounds.bottom - screenBounds.bottom) < 80 &&
        abs(browserBounds.top - screenBounds.top) < 160
}

private func onScreenWindows(appName: String) -> [OnScreenWindow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let rawWindows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
        return []
    }

    return rawWindows.compactMap { window in
        guard let owner = window[kCGWindowOwnerName as String] as? String,
              owner == appName,
              let title = window[kCGWindowName as String] as? String,
              !title.isEmpty,
              let rawBounds = window[kCGWindowBounds as String] as? [String: Any],
              let x = rawBounds["X"] as? Double,
              let y = rawBounds["Y"] as? Double,
              let width = rawBounds["Width"] as? Double,
              let height = rawBounds["Height"] as? Double,
              width > 80,
              height > 80 else {
            return nil
        }

        return OnScreenWindow(
            ownerName: owner,
            title: title,
            bounds: WindowBounds(left: x, top: y, right: x + width, bottom: y + height)
        )
    }
}

private func bringProcessToFront(appName: String) -> Bool {
    let script = """
    tell application "System Events"
      try
        set visible of process "\(appleScriptEscaped(appName))" to true
        set frontmost of process "\(appleScriptEscaped(appName))" to true
        return "ok"
      end try
    end tell
    return "missing"
    """

    return runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
}

private func raiseProcessWindow(appName: String) -> Bool {
    let script = """
    tell application "System Events"
      tell process "\(appleScriptEscaped(appName))"
        try
          perform action "AXRaise" of window 1
        end try
        try
          set frontmost to true
        end try
      end tell
    end tell
    return "ok"
    """

    return runAppleScript(script, timeout: 1.0)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
}

private func activateApp(appName: String, bundleIdentifier: String?) -> Bool {
    if let bundleIdentifier,
       let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
        app.activate(options: [.activateIgnoringOtherApps])
    } else if let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) {
        app.activate(options: [.activateIgnoringOtherApps])
    }

    _ = runAppleScript(#"tell application "\#(appleScriptEscaped(appName))" to activate"#, timeout: 1.0)
    _ = bringProcessToFront(appName: appName)

    let deadline = Date().addingTimeInterval(1.2)
    while Date() < deadline {
        if NSWorkspace.shared.frontmostApplication?.localizedName == appName ||
            systemEventsFrontmostProcessName() == appName {
            return true
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    _ = shell("/usr/bin/open -a \(shellQuoted(appName))")
    _ = bringProcessToFront(appName: appName)
    Thread.sleep(forTimeInterval: 0.3)
    return NSWorkspace.shared.frontmostApplication?.localizedName == appName ||
        systemEventsFrontmostProcessName() == appName
}

private func waitForKeyboardFocus(appName: String, timeout: TimeInterval = 1.6) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    var sawNSFrontmost = false
    while Date() < deadline {
        let nsFrontmost = NSWorkspace.shared.frontmostApplication?.localizedName
        let seFrontmost = systemEventsFrontmostProcessName()
        if nsFrontmost == appName, seFrontmost == appName {
            return true
        }
        if nsFrontmost == appName {
            sawNSFrontmost = true
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    return sawNSFrontmost || NSWorkspace.shared.frontmostApplication?.localizedName == appName
}

private func systemEventsFrontmostProcessName() -> String? {
    runAppleScript(
        #"tell application "System Events" to get name of first process whose frontmost is true"#,
        timeout: 1.0
    )?.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isFrontmostApp(named appName: String) -> Bool {
    NSWorkspace.shared.frontmostApplication?.localizedName == appName ||
        systemEventsFrontmostProcessName() == appName
}

private func returnToSource(_ source: SourceWindow) {
    if let windowID = source.windowID, chromiumBrowserNames.contains(source.appName) {
        let script = """
        tell application "\(appleScriptEscaped(source.appName))"
          try
            set index of window id \(windowID) to 1
            activate
            return "ok"
          end try
        end tell
        return "missing"
        """
        if runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" {
            return
        }
    }

    if let bundleID = source.bundleIdentifier,
       let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
        app.activate(options: [.activateIgnoringOtherApps])
    }
}

private func loadTarget() -> TargetDocument? {
    guard let data = try? Data(contentsOf: targetFile) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(TargetDocument.self, from: data)
}

private func saveTarget(_ target: TargetDocument) -> Bool {
    ensureSupportDirectory()
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(target).write(to: targetFile, options: .atomic)
        log("saved target: \(target.title) \(target.focusPoint == nil ? "without body point" : "with body point") \(target.url)")
        return true
    } catch {
        log("target save error: \(error)")
        return false
    }
}

private func parseBounds(_ value: String) -> WindowBounds? {
    let parts = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 4 else { return nil }
    return WindowBounds(left: parts[0], top: parts[1], right: parts[2], bottom: parts[3])
}

private func isGoogleDocumentURL(_ url: String) -> Bool {
    url.hasPrefix("https://docs.google.com/document/d/") ||
        url.hasPrefix("http://docs.google.com/document/d/")
}

private func keyCombo(_ keyCode: CGKeyCode, flags: CGEventFlags) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }

    if flags.contains(.maskCommand) {
        CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: true)?.post(tap: .cghidEventTap)
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
        CGEvent(keyboardEventSource: source, virtualKey: keyCodeCommand, keyDown: false)?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.015)
    }
}

private func clickScreenPoint(_ point: CGPoint) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { return }
    CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.04)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.04)
    CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}

private func currentMouseTargetFocusPoint(bounds: WindowBounds?) -> TargetFocusPoint? {
    guard let bounds,
          let mouseEvent = CGEvent(source: nil) else {
        return nil
    }

    let point = mouseEvent.location
    guard bounds.contains(point, tolerance: 0),
          point.y >= bounds.documentBodyTop,
          point.y <= bounds.bottom - 20,
          point.x >= bounds.left + 40,
          point.x <= bounds.right - 40 else {
        return nil
    }

    return TargetFocusPoint(
        x: point.x,
        y: point.y,
        relativeX: (point.x - bounds.left) / bounds.width,
        relativeY: (point.y - bounds.top) / bounds.height
    )
}

private func clickTargetFocusPoint(_ focusPoint: TargetFocusPoint?, bounds: WindowBounds?) {
    guard let focusPoint,
          let bounds else {
        log("no saved target body click point")
        return
    }

    let point = CGPoint(
        x: bounds.left + bounds.width * focusPoint.relativeX,
        y: bounds.top + bounds.height * focusPoint.relativeY
    )

    guard bounds.contains(point, tolerance: 0),
          point.y >= bounds.documentBodyTop,
          point.y <= bounds.bottom - 20,
          point.x >= bounds.left + 40,
          point.x <= bounds.right - 40 else {
        log("saved target body click point ignored")
        return
    }

    clickScreenPoint(point)
    Thread.sleep(forTimeInterval: 0.15)
    log("clicked saved target body point")
}

private func systemEventsKeystroke(_ character: String, usingCommand: Bool, targetProcessName: String? = nil) -> Bool {
    let modifiers = usingCommand ? " using command down" : ""
    let script: String
    if let targetProcessName {
        script = """
        tell application "System Events"
          tell process "\(appleScriptEscaped(targetProcessName))"
            set frontmost to true
            keystroke "\(appleScriptEscaped(character))"\(modifiers)
          end tell
        end tell
        """
    } else {
        script = #"tell application "System Events" to keystroke "\#(appleScriptEscaped(character))"\#(modifiers)"#
    }

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", script]
    task.standardOutput = Pipe()
    task.standardError = Pipe()
    do {
        try task.run()
    } catch {
        log("System Events keystroke failed to start: \(error)")
        return false
    }

    let deadline = Date().addingTimeInterval(1.5)
    while task.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.03)
    }

    if task.isRunning {
        task.terminate()
        log("System Events keystroke timed out")
        return false
    }

    if task.terminationStatus != 0 {
        log("System Events keystroke failed with status \(task.terminationStatus)")
        return false
    }
    return true
}

private func isAppRunning(appName: String) -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.localizedName == appName }
}

private func runAppleScript(_ source: String, timeout: TimeInterval = 3.0) -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    task.arguments = ["-e", source]

    let outputPipe = Pipe()
    let errorPipe = Pipe()
    task.standardOutput = outputPipe
    task.standardError = errorPipe

    do {
        try task.run()
    } catch {
        log("AppleScript failed to start: \(error)")
        return nil
    }

    let deadline = Date().addingTimeInterval(timeout)
    while task.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.03)
    }

    if task.isRunning {
        task.terminate()
        log("AppleScript timed out")
        return nil
    }

    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
    if task.terminationStatus != 0 {
        let message = String(data: errorData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        log("AppleScript failed with status \(task.terminationStatus): \(message)")
        return nil
    }

    return String(data: outputData, encoding: .utf8)?
        .trimmingCharacters(in: .newlines)
}

private func appleScriptEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

private func ensureSupportDirectory() {
    try? FileManager.default.createDirectory(
        at: supportDirectory,
        withIntermediateDirectories: true
    )
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

private func installPath() -> String {
    CommandLine.arguments.first ?? "CapsDocsCapture"
}

private func usage() {
    print("""
    Usage:
      CapsDocsCapture --daemon                  Listen for Caps Lock/F18 captures
      CapsDocsCapture --trigger-daemon          Ask the running daemon to capture once
      CapsDocsCapture --once                    Capture selected text once
      CapsDocsCapture --set-target              Save the focused Google Docs window
      CapsDocsCapture --set-target-url TEXT     Save the open Doc whose URL contains TEXT
      CapsDocsCapture --set-target-title TEXT   Save the open Doc whose title contains TEXT
      CapsDocsCapture --list-docs               List open Google Docs documents
      CapsDocsCapture --map-capslock            Map Caps Lock to F18 now
      CapsDocsCapture --unmap-capslock          Remove this session's key mapping
      CapsDocsCapture --stop                    Stop daemon and restore Caps Lock
      CapsDocsCapture --request-accessibility   Ask macOS for Accessibility access
      CapsDocsCapture --status                  Show current configuration
    """)
}

private let rawArguments = Array(CommandLine.arguments.dropFirst())
private let arguments = Set(rawArguments)
private let controller = CaptureController()

if arguments.contains("--daemon") {
    controller.runDaemon()
} else if arguments.contains("--trigger-daemon") {
    triggerDaemon()
} else if arguments.contains("--once") {
    exit(controller.captureOnce() ? 0 : 1)
} else if arguments.contains("--set-target") {
    exit(setTargetToFrontDocument() ? 0 : 1)
} else if let index = rawArguments.firstIndex(of: "--set-target-url"),
          rawArguments.indices.contains(index + 1) {
    exit(setTargetBySearch(rawArguments[index + 1], mode: .url) ? 0 : 1)
} else if let index = rawArguments.firstIndex(of: "--set-target-title"),
          rawArguments.indices.contains(index + 1) {
    exit(setTargetBySearch(rawArguments[index + 1], mode: .title) ? 0 : 1)
} else if arguments.contains("--list-docs") {
    listGoogleDocuments()
} else if arguments.contains("--map-capslock") {
    exit(applyCapsLockMapping() ? 0 : 1)
} else if arguments.contains("--unmap-capslock") {
    exit(removeCapsLockMapping() ? 0 : 1)
} else if arguments.contains("--stop") {
    exit(stopDaemon() ? 0 : 1)
} else if arguments.contains("--request-accessibility") {
    requestAccessibility()
} else if arguments.contains("--status") {
    status()
} else {
    usage()
}
