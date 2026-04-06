import Cocoa
import AVFoundation
import SoundAnalysis
import CoreMedia
import CoreAudio
import ServiceManagement

let kAppVersion = "1.0.0"
let kGitHubRepo = "a159x36/ImHear"

// ═══════════════════════════════════════════════════════════
// MARK: - System Helpers
// ═══════════════════════════════════════════════════════════

func checkIsPlaying() -> Bool {
    let s = "function run(){var M=$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework/');M.load;var r=$.NSClassFromString('MRNowPlayingRequest');var i=r.localNowPlayingItem;if(!i)return'no';var n=i.nowPlayingInfo;if(!n)return'no';var t=n.valueForKey('kMRMediaRemoteNowPlayingInfoPlaybackRate');if(!t)return'no';return t.js==1?'yes':'no';}"
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-l","JavaScript","-e",s]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
    do { try p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) == "yes"
    } catch { return false }
}

func sendMediaPlayPause() {
    for d in [true, false] {
        let f = d ? 0xa00 : 0xb00
        guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero,
            modifierFlags: .init(rawValue: UInt(f)), timestamp: 0, windowNumber: 0, context: nil,
            subtype: 8, data1: Int((16 << 16)|f), data2: -1) else { continue }
        e.cgEvent?.post(tap: .cghidEventTap)
    }
}

func getSystemVolume() -> Float {
    var id = AudioDeviceID(0); var sz = UInt32(MemoryLayout.size(ofValue: id))
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id)
    var v: Float32 = 0; sz = UInt32(MemoryLayout.size(ofValue: v))
    a.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    a.mScope = kAudioDevicePropertyScopeOutput
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v); return v
}

func setSystemVolume(_ v: Float) {
    var id = AudioDeviceID(0); var sz = UInt32(MemoryLayout.size(ofValue: id))
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id)
    var vol = v; sz = UInt32(MemoryLayout.size(ofValue: vol))
    a.mSelector = kAudioHardwareServiceDeviceProperty_VirtualMainVolume
    a.mScope = kAudioDevicePropertyScopeOutput
    AudioObjectSetPropertyData(id, &a, 0, nil, sz, &vol)
}

// Safe CoreAudio CFString property reader (avoids ARC corruption with raw pointer)
private func audioStringProperty(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
                                  _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var rawPtr: UnsafeRawPointer? = nil
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rawPtr) == noErr,
          let ptr = rawPtr else { return "" }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func getInputDevices() -> [(name: String, uid: String)] {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ds = [AudioDeviceID](repeating: 0, count: Int(sz)/MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ds)
    var r: [(String,String)] = []
    for d in ds {
        var ia = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var bs: UInt32 = 0; AudioObjectGetPropertyDataSize(d, &ia, 0, nil, &bs)
        guard bs > 0 else { continue }
        // AudioBufferList is variable-length; allocate exact size from GetPropertyDataSize
        let bl = UnsafeMutableRawPointer.allocate(byteCount: Int(bs), alignment: MemoryLayout<AudioBufferList>.alignment)
        AudioObjectGetPropertyData(d, &ia, 0, nil, &bs, bl)
        let bufList = bl.assumingMemoryBound(to: AudioBufferList.self)
        let ok = bufList.pointee.mNumberBuffers > 0 && bufList.pointee.mBuffers.mNumberChannels > 0
        bl.deallocate(); guard ok else { continue }
        let nm = audioStringProperty(d, kAudioDevicePropertyDeviceNameCFString)
        let uid = audioStringProperty(d, kAudioDevicePropertyDeviceUID)
        r.append((nm, uid))
    }; return r
}

func getDefaultInputUID() -> String {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id = AudioDeviceID(0); var sz = UInt32(MemoryLayout.size(ofValue: id))
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &id)
    return audioStringProperty(id, kAudioDevicePropertyDeviceUID)
}

func setDefaultInputDevice(uid: String) {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
    var ds = [AudioDeviceID](repeating: 0, count: Int(sz)/MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ds)
    for d in ds {
        let du = audioStringProperty(d, kAudioDevicePropertyDeviceUID)
        if du == uid {
            var devID = d
            var sa = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &sa, 0, nil,
                UInt32(MemoryLayout<AudioDeviceID>.size), &devID); return
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Permission Banner
// ═══════════════════════════════════════════════════════════

class PermissionBanner: NSView {
    var onClick: (() -> Void)?

    init(frame: NSRect, icon: String, text: String) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.13).cgColor

        let iLbl = NSTextField(frame: NSRect(x: 8, y: (frame.height-16)/2, width: 16, height: 16))
        iLbl.stringValue = icon; iLbl.isEditable = false; iLbl.isBordered = false
        iLbl.drawsBackground = false; iLbl.font = .systemFont(ofSize: 11)
        addSubview(iLbl)

        let tLbl = NSTextField(frame: NSRect(x: 26, y: (frame.height-14)/2, width: frame.width - 56, height: 14))
        tLbl.stringValue = text; tLbl.isEditable = false; tLbl.isBordered = false
        tLbl.drawsBackground = false; tLbl.font = .systemFont(ofSize: 10.5, weight: .medium)
        tLbl.textColor = .secondaryLabelColor; tLbl.lineBreakMode = .byTruncatingTail
        addSubview(tLbl)

        let arrow = NSTextField(frame: NSRect(x: frame.width - 26, y: (frame.height-14)/2, width: 20, height: 14))
        arrow.stringValue = "Fix"; arrow.isEditable = false; arrow.isBordered = false
        arrow.drawsBackground = false; arrow.font = .systemFont(ofSize: 10, weight: .semibold)
        arrow.textColor = .systemBlue; arrow.alignment = .right
        addSubview(arrow)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with e: NSEvent) {
        alphaValue = 0.6
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.alphaValue = 1.0 }
        onClick?()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Permission Helpers
// ═══════════════════════════════════════════════════════════

func isMicGranted() -> Bool {
    let s = AVCaptureDevice.authorizationStatus(for: .audio)
    // .notDetermined = system dialog already shown by AVAudioEngine, don't show banner
    return s == .authorized || s == .notDetermined
}

func isAccessibilityGranted() -> Bool {
    AXIsProcessTrusted()
}

func openMicSettings() {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    if status == .notDetermined {
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    } else {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

func isLaunchAtLoginEnabled() -> Bool {
    guard Bundle.main.bundleIdentifier != nil else { return false }
    return SMAppService.mainApp.status == .enabled
}

func setLaunchAtLogin(_ enabled: Bool) {
    guard Bundle.main.bundleIdentifier != nil else { return }
    do {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    } catch { }
}

// ═══════════════════════════════════════════════════════════
// MARK: - MeterSlider
// ═══════════════════════════════════════════════════════════

class MeterSlider: NSView {
    var level: CGFloat = 0
    var threshold: CGFloat = 0.5
    var barColor: NSColor = .systemCyan
    var onChange: ((Float) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 5
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(level: CGFloat, threshold: CGFloat) {
        self.level = level; self.threshold = threshold; needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        let barW = b.width * min(level, 1.0)
        let c: NSColor = level >= threshold && threshold > 0.005 ? .systemRed :
            level >= threshold * 0.7 && threshold > 0.005 ? .systemOrange : barColor
        c.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: barW, height: b.height), xRadius: 5, yRadius: 5).fill()
        NSColor.white.withAlphaComponent(0.12).setFill()
        for i in 1..<10 { NSRect(x: b.width * CGFloat(i)/10, y: 0, width: 1, height: b.height).fill() }
        if threshold > 0.005 {
            let tx = b.width * min(max(threshold, 0), 1.0)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: NSRect(x: tx-2, y: 0, width: 4, height: b.height), xRadius: 2, yRadius: 2).fill()
            NSColor.black.withAlphaComponent(0.25).setFill()
            NSRect(x: tx-0.5, y: 0, width: 1, height: b.height).fill()
        }
    }

    override func mouseDown(with e: NSEvent) { drag(e) }
    override func mouseDragged(with e: NSEvent) { drag(e) }
    private func drag(_ e: NSEvent) {
        let x = convert(e.locationInWindow, from: nil).x
        let v = Float(max(0, min(x / bounds.width, 1.0)))
        threshold = CGFloat(v); onChange?(v); needsDisplay = true
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Auto Updater
// ═══════════════════════════════════════════════════════════

class UpdateChecker {
    struct Release {
        let version: String
        let downloadURL: URL
    }

    var latestRelease: Release?
    var isUpdateAvailable: Bool { latestRelease != nil && latestRelease!.version != kAppVersion }
    private var checkTimer: Timer?

    func startPeriodicCheck(interval: TimeInterval = 3 * 3600) {
        check(nil)
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.check(nil)
        }
    }

    func check(_ completion: ((Bool) -> Void)?) {
        let url = URL(string: "https://api.github.com/repos/\(kGitHubRepo)/releases/latest")!
        var req = URLRequest(url: url); req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let data = data, err == nil,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]] else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let dmgAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                ?? assets.first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
                ?? assets.first
            let dlURL = (dmgAsset?["browser_download_url"] as? String).flatMap { URL(string: $0) }
            DispatchQueue.main.async {
                if let dlURL = dlURL {
                    self?.latestRelease = Release(version: ver, downloadURL: dlURL)
                }
                completion?(ver != kAppVersion)
            }
        }.resume()
    }

    func downloadAndInstall() {
        guard let release = latestRelease, isUpdateAvailable else { return }
        let url = release.downloadURL
        URLSession.shared.downloadTask(with: url) { tmpURL, response, err in
            guard let tmpURL = tmpURL, err == nil else {
                DispatchQueue.main.async {
                    let a = NSAlert(); a.messageText = "Update Failed"
                    a.informativeText = err?.localizedDescription ?? "Download failed"
                    a.runModal()
                }
                return
            }
            DispatchQueue.main.async { self.installUpdate(from: tmpURL, filename: url.lastPathComponent) }
        }.resume()
    }

    private func installUpdate(from tmpFile: URL, filename: String) {
        let appPath = Bundle.main.bundlePath.isEmpty
            ? "/Users/\(NSUserName())/Applications/ImHear.app"
            : Bundle.main.bundlePath
        let appURL = URL(fileURLWithPath: appPath)
        let parentDir = appURL.deletingLastPathComponent()

        do {
            if filename.hasSuffix(".zip") {
                let unzipDir = FileManager.default.temporaryDirectory.appendingPathComponent("ImHear_update")
                try? FileManager.default.removeItem(at: unzipDir)
                try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                proc.arguments = ["-o", tmpFile.path, "-d", unzipDir.path]
                proc.standardOutput = Pipe(); proc.standardError = Pipe()
                try proc.run(); proc.waitUntilExit()

                // Find .app in unzipped contents
                let contents = try FileManager.default.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)
                guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                    let a = NSAlert(); a.messageText = "Update Failed"
                    a.informativeText = "No .app found in archive"; a.runModal(); return
                }
                // Replace current app
                try? FileManager.default.removeItem(at: appURL)
                try FileManager.default.moveItem(at: newApp, to: appURL)
            } else {
                // Direct binary or .app replacement
                try? FileManager.default.removeItem(at: appURL)
                try FileManager.default.moveItem(at: tmpFile, to: parentDir.appendingPathComponent(filename))
            }

            // Relaunch
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = [appURL.path]
            try task.run()
            NSApp.terminate(nil)
        } catch {
            let a = NSAlert(); a.messageText = "Update Failed"
            a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - App Delegate
// ═══════════════════════════════════════════════════════════

enum ActionMode: Int { case pauseMedia = 0, volumeDown = 1 }

// ═══════════════════════════════════════════════════════════
// MARK: - UserDefaults Keys
// ═══════════════════════════════════════════════════════════

private enum UDKey {
    static let sensitivity      = "sensitivity"
    static let volumeThreshold  = "volumeThreshold"
    static let resumeDelay      = "resumeDelay"
    static let actionMode       = "actionMode"
    static let targetVolume     = "targetVolume"
    static let isEnabled        = "isEnabled"
    static let showMeter        = "showMeter"
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var popoverVC: SettingsVC!
    var soundDetector: SoundDetector!
    let updateChecker = UpdateChecker()
    var eventMonitor: Any?

    var isEnabled = true
    var isPausedByUs = false
    var isVolumeDownByUs = false
    var savedVolume: Float = 0.5

    var sensitivity: Float = 0.5      { didSet { if didLoad { UserDefaults.standard.set(sensitivity, forKey: UDKey.sensitivity) } } }
    var volumeThreshold: Float = 0.10 { didSet { if didLoad { UserDefaults.standard.set(volumeThreshold, forKey: UDKey.volumeThreshold) } } }
    var resumeDelay: TimeInterval = 3.0 { didSet { if didLoad { UserDefaults.standard.set(resumeDelay, forKey: UDKey.resumeDelay) } } }
    var actionMode: ActionMode = .pauseMedia { didSet { if didLoad { UserDefaults.standard.set(actionMode.rawValue, forKey: UDKey.actionMode) } } }
    var targetVolume: Float = 0.1     { didSet { if didLoad { UserDefaults.standard.set(targetVolume, forKey: UDKey.targetVolume) } } }
    var showMeter: Bool = true        { didSet { if didLoad { UserDefaults.standard.set(showMeter, forKey: UDKey.showMeter) } } }
    var resumeTimer: Timer?
    var resumeFireTime: Date?
    private var didLoad = false

    private var _isSpeaking = false
    private var displayTimer: Timer?
    // CoreAudio device-change listener
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    func applicationDidFinishLaunching(_ n: Notification) {
        loadDefaults(); didLoad = true
        soundDetector = SoundDetector(); soundDetector.delegate = self
        setupStatusBar()
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if isEnabled { soundDetector.start() }
        registerSleepWake()
        registerDeviceListener()
        // Live meter update in status bar
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.redrawStatusIcon()
        }
        // Check for updates every 3 hours
        updateChecker.startPeriodicCheck()
    }

    // ── UserDefaults ──────────────────────────────────────
    private func loadDefaults() {
        let d = UserDefaults.standard
        d.register(defaults: [
            UDKey.sensitivity: 0.5,
            UDKey.volumeThreshold: 0.10,
            UDKey.resumeDelay: 3.0,
            UDKey.actionMode: ActionMode.pauseMedia.rawValue,
            UDKey.targetVolume: 0.1,
            UDKey.isEnabled: true,
            UDKey.showMeter: true,
        ])
        sensitivity      = d.float(forKey: UDKey.sensitivity)
        volumeThreshold  = d.float(forKey: UDKey.volumeThreshold)
        resumeDelay      = d.double(forKey: UDKey.resumeDelay)
        actionMode       = ActionMode(rawValue: d.integer(forKey: UDKey.actionMode)) ?? .pauseMedia
        targetVolume     = d.float(forKey: UDKey.targetVolume)
        isEnabled        = d.bool(forKey: UDKey.isEnabled)
        showMeter        = d.bool(forKey: UDKey.showMeter)
    }

    func saveEnabled() { UserDefaults.standard.set(isEnabled, forKey: UDKey.isEnabled) }

    // ── Sleep / Wake ──────────────────────────────────────
    private func registerSleepWake() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleWake),  name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(handleWake),  name: NSWorkspace.screensDidWakeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleSleep),
            name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(handleWake),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func handleSleep(_ n: Notification) {
        soundDetector.stop()
        // During sleep: restore volume if lowered, clear state, but don't spawn subprocess
        if isVolumeDownByUs { setSystemVolume(savedVolume); isVolumeDownByUs = false }
        isPausedByUs = false
        resumeTimer?.invalidate(); resumeTimer = nil; resumeFireTime = nil
        updateIcon(speaking: false)
    }

    @objc private func handleWake(_ n: Notification) {
        guard isEnabled else { return }
        // small delay for audio hardware to re-init
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.soundDetector.start()
        }
    }

    // ── Audio Device Change Listener ─────────────────────
    private func registerDeviceListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.handleDeviceChange() }
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    private func handleDeviceChange() {
        let wasRunning = soundDetector.isRunning
        let gain = soundDetector.micGain
        soundDetector.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.soundDetector.micGain = gain
            if wasRunning && self.isEnabled { self.soundDetector.start() }
            // refresh popover mic list if open
            self.popoverVC?.reloadMicList()
        }
    }

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(speaking: false)
        statusItem.button?.action = #selector(togglePopover(_:)); statusItem.button?.target = self
    }

    func updateIcon(speaking: Bool) {
        _isSpeaking = speaking
        redrawStatusIcon()
    }

    func redrawStatusIcon() {
        guard let b = statusItem.button else { return }

        // ── meter values ──
        let speech = CGFloat(soundDetector.currentSpeechConfidence)
        let vol = CGFloat(soundDetector.currentVolumeLevel)
        let normSpeech = sensitivity > 0.005 ? min(speech / CGFloat(sensitivity), 1.0) : min(speech * 2, 1.0)
        let normVol = volumeThreshold > 0.005 ? min(vol / CGFloat(volumeThreshold), 1.0) : 1.0
        let level = normSpeech * normVol  // reaches 1.0 only when BOTH hit threshold
        let maxDisp: CGFloat = 1.15      // visual headroom above threshold

        // ── icon state ──
        let earName: String
        let earColor: NSColor
        let alpha: CGFloat
        let isDark = b.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let defaultColor: NSColor = isDark ? .white : .black

        if !isEnabled {
            earName = "ear.fill"; earColor = defaultColor.withAlphaComponent(0.4); alpha = 1.0
        } else if _isSpeaking {
            earName = "ear.badge.waveform"; earColor = .systemOrange; alpha = 1.0
        } else if isPausedByUs || isVolumeDownByUs {
            earName = "ear.fill"; earColor = .systemYellow; alpha = 1.0
        } else {
            earName = "ear.fill"; earColor = defaultColor; alpha = 1.0
        }

        // ── capture for drawing block ──
        let meter = showMeter
        let enabled = isEnabled
        let lvl = level, maxD = maxDisp

        let imgW: CGFloat = meter ? 26 : 18, imgH: CGFloat = 18
        let img = NSImage(size: NSSize(width: imgW, height: imgH), flipped: false) { _ in
            // Ear icon
            let earX: CGFloat = meter ? 0 : 1
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [earColor]))
            if let ear = NSImage(systemSymbolName: earName, accessibilityDescription: "ImHear")?
                .withSymbolConfiguration(cfg) {
                ear.draw(in: NSRect(x: earX, y: 1, width: 16, height: 16))
            }

            // Meter bar (only if enabled)
            if meter {
                let barX: CGFloat = 19, barW: CGFloat = 5, barH: CGFloat = 14
                let barY: CGFloat = (imgH - barH) / 2

                // Background
                (isDark ? NSColor.white : NSColor.black).withAlphaComponent(0.12).setFill()
                NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: barW, height: barH),
                             xRadius: 1.5, yRadius: 1.5).fill()

                if enabled {
                    // Fill
                    let fillRatio = min(lvl / maxD, 1.0)
                    let fillH = barH * fillRatio
                    let fillColor: NSColor = lvl >= 1.0 ? .systemRed
                        : lvl >= 0.7 ? .systemOrange : .systemGreen
                    fillColor.setFill()
                    let fillRect = NSRect(x: barX, y: barY, width: barW, height: fillH)
                    NSBezierPath(roundedRect: fillRect, xRadius: 1.5, yRadius: 1.5).fill()

                    // Threshold line at 1.0/maxDisp
                    let threshY = barY + barH * (1.0 / maxD)
                    NSColor.white.withAlphaComponent(0.9).setFill()
                    NSRect(x: barX - 1, y: threshY - 0.5, width: barW + 2, height: 1).fill()
                }
            }
            return true
        }
        img.isTemplate = false
        b.image = img
        b.alphaValue = alpha
    }

    @objc func togglePopover(_ sender: Any?) {
        if let p = popover, p.isShown { p.performClose(sender); return }
        popoverVC = SettingsVC(); popoverVC.app = self
        // Force view creation BEFORE popover association to avoid AppKit appearance crash
        let contentSize = popoverVC.view.frame.size
        popover = NSPopover(); popover.contentViewController = popoverVC
        popover.behavior = .transient; popover.delegate = self
        popover.contentSize = contentSize
        if let b = statusItem.button { popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY) }
        let (t, c) = currentStatusText()
        popoverVC.refreshStatus(text: t, color: c)
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover?.performClose(nil)
        }
    }

    func popoverDidClose(_ n: Notification) {
        if let e = eventMonitor { NSEvent.removeMonitor(e); eventMonitor = nil }; popoverVC = nil
    }

    func triggerAction() {
        switch actionMode {
        case .pauseMedia:
            guard !isPausedByUs else { return }
            sendMediaPlayPause(); isPausedByUs = true
        case .volumeDown:
            guard !isVolumeDownByUs else { return }
            savedVolume = getSystemVolume()
            setSystemVolume(targetVolume); isVolumeDownByUs = true
        }
        updateIcon(speaking: true); popoverVC?.refreshStatus(text: statusTextForAction(), color: .systemYellow)
        scheduleResume()
    }

    func scheduleResume() {
        guard resumeDelay >= 1 else { return }
        resumeTimer?.invalidate()
        resumeFireTime = Date().addingTimeInterval(resumeDelay)
        resumeTimer = Timer.scheduledTimer(withTimeInterval: resumeDelay, repeats: false) { [weak self] _ in
            guard let s = self, s.isActionActive else { self?.resumeTimer = nil; self?.resumeFireTime = nil; return }
            s.restoreMedia()
        }
    }

    func restoreMedia() {
        let wasPaused = isPausedByUs
        isPausedByUs = false
        if isVolumeDownByUs { setSystemVolume(savedVolume); isVolumeDownByUs = false }
        resumeTimer?.invalidate(); resumeTimer = nil; resumeFireTime = nil
        updateIcon(speaking: false); popoverVC?.refreshStatus()
        if wasPaused {
            // Async check: only send play if media is still actually paused
            DispatchQueue.global(qos: .userInitiated).async {
                if !checkIsPlaying() { sendMediaPlayPause() }
            }
        }
    }

    var isActionActive: Bool { isPausedByUs || isVolumeDownByUs }

    func currentStatusText() -> (String, NSColor) {
        if !isEnabled { return ("Disabled", .tertiaryLabelColor) }
        if isPausedByUs { return ("⏸ Media paused", .systemYellow) }
        if isVolumeDownByUs { return ("🔉 Volume lowered", .systemYellow) }
        if resumeTimer != nil { return ("Resume in \(Int(resumeDelay))s…", .secondaryLabelColor) }
        return ("Listening…", .secondaryLabelColor)
    }

    func statusTextForAction() -> String {
        actionMode == .pauseMedia ? "⏸ Media paused" : "🔉 Volume lowered"
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - SoundDetector Delegate
// ═══════════════════════════════════════════════════════════

extension AppDelegate: SoundDetectorDelegate {
    func soundDetector(_ d: SoundDetector, didDetectSpeech label: String, confidence: Float) {
        let vol = d.currentVolumeLevel
        guard isEnabled, confidence >= sensitivity else { return }
        guard volumeThreshold <= 0.005 || vol >= volumeThreshold else { return }

        DispatchQueue.main.async { [weak self] in
            guard let s = self else { return }
            s.updateIcon(speaking: true)
            s.popoverVC?.refreshStatus(text: "\(label) (\(Int(confidence*100))%)", color: .systemOrange)

            if s.isActionActive {
                // Speech while action active → reset countdown
                s.scheduleResume()
            } else {
                if s.actionMode == .pauseMedia {
                    DispatchQueue.global(qos: .userInitiated).async {
                        let ok = checkIsPlaying()
                        DispatchQueue.main.async { guard ok, !s.isActionActive else { return }; s.triggerAction() }
                    }
                } else { s.triggerAction() }
            }
        }
    }

    func soundDetector(_ d: SoundDetector, didDetectSilence topSound: String) {
        guard isEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            guard let s = self else { return }
            s.updateIcon(speaking: false)
            if s.isActionActive {
                if s.resumeDelay < 1 {
                    s.popoverVC?.refreshStatus(text: "Paused (manual)", color: .systemYellow)
                }
                // else: countdown already running from triggerAction/scheduleResume
            } else { s.popoverVC?.refreshStatus() }
        }
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Settings VC
// ═══════════════════════════════════════════════════════════

class SettingsVC: NSViewController {
    weak var app: AppDelegate!
    var statusLabel: NSTextField!
    var speechMeter: MeterSlider!
    var volumeMeter: MeterSlider!
    var speechVal: NSTextField!
    var volumeVal: NSTextField!
    var targetVolSlider: NSSlider!
    var targetVolLabel: NSTextField!
    var delayLabel: NSTextField!
    var micPopup: NSPopUpButton!
    var versionLabel: NSTextField!
    var updateBtn: NSButton!
    var timer: Timer?
    var micBanner: PermissionBanner?
    var axBanner: PermissionBanner?

    override func loadView() {
        let W: CGFloat = 300
        let P: CGFloat = 16, iW = W - P*2
        let bannerH: CGFloat = 28, bannerGap: CGFloat = 6
        let needMic = !isMicGranted()
        let needAx  = !isAccessibilityGranted()
        let bannerCount = (needMic ? 1 : 0) + (needAx ? 1 : 0)
        let bannerSpace = CGFloat(bannerCount) * (bannerH + bannerGap)
        let H: CGFloat = 510 + bannerSpace

        view = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))
        view.wantsLayer = true
        var y = H - 10

        // Header
        y -= 24
        view.addSubview(lbl(P, y, 100, 20, "👂 ImHear", .systemFont(ofSize: 15, weight: .bold)))
        view.addSubview(lbl(P+100, y+3, iW-100, 16, "I'm all ears",
            .systemFont(ofSize: 10, weight: .light), .tertiaryLabelColor, .right))

        y -= 18
        statusLabel = lbl(P, y, iW, 14, "Listening…", .systemFont(ofSize: 11), .secondaryLabelColor)
        view.addSubview(statusLabel)

        // Permission banners
        if needMic {
            y -= (bannerH + bannerGap)
            let b = PermissionBanner(frame: NSRect(x: P, y: y, width: iW, height: bannerH),
                icon: "🎤", text: "Microphone access required")
            b.onClick = { openMicSettings() }
            view.addSubview(b); micBanner = b
        }
        if needAx {
            y -= (bannerH + bannerGap)
            let b = PermissionBanner(frame: NSRect(x: P, y: y, width: iW, height: bannerH),
                icon: "🔐", text: "Accessibility access required")
            b.onClick = { openAccessibilitySettings() }
            view.addSubview(b); axBanner = b
        }

        // Enable toggle
        y -= 28
        let tog = NSButton(frame: NSRect(x: P, y: y, width: iW, height: 20))
        tog.setButtonType(.switch); tog.title = " Enable Detection"
        tog.font = .systemFont(ofSize: 12, weight: .medium)
        tog.state = app.isEnabled ? .on : .off
        tog.target = self; tog.action = #selector(togEnable(_:))
        view.addSubview(tog)

        y -= 8; addSep(y)

        // Mic
        y -= 16; view.addSubview(sec(P, y, "MICROPHONE"))
        y -= 24
        micPopup = NSPopUpButton(frame: NSRect(x: P, y: y, width: iW, height: 20), pullsDown: false)
        micPopup.font = .systemFont(ofSize: 11); micPopup.controlSize = .small
        populateMicList()
        micPopup.target = self; micPopup.action = #selector(micPick(_:))
        view.addSubview(micPopup)

        y -= 8; addSep(y)

        // Action
        y -= 16; view.addSubview(sec(P, y, "ACTION"))
        y -= 22
        let r1 = NSButton(radioButtonWithTitle: " ⏸ Pause", target: self, action: #selector(actPick(_:)))
        r1.frame = NSRect(x: P, y: y, width: iW/2, height: 18); r1.font = .systemFont(ofSize: 11)
        r1.tag = 0; r1.state = app.actionMode == .pauseMedia ? .on : .off; view.addSubview(r1)
        let r2 = NSButton(radioButtonWithTitle: " 🔉 Vol Down", target: self, action: #selector(actPick(_:)))
        r2.frame = NSRect(x: P+iW/2, y: y, width: iW/2, height: 18); r2.font = .systemFont(ofSize: 11)
        r2.tag = 1; r2.state = app.actionMode == .volumeDown ? .on : .off; view.addSubview(r2)

        y -= 22
        view.addSubview(lbl(P, y+2, 65, 14, "Target Vol", .systemFont(ofSize: 10, weight: .medium), .secondaryLabelColor))
        targetVolSlider = NSSlider(frame: NSRect(x: P+68, y: y, width: iW-112, height: 18))
        targetVolSlider.minValue = 0; targetVolSlider.maxValue = 50
        targetVolSlider.integerValue = Int(app.targetVolume*100)
        targetVolSlider.controlSize = .small; targetVolSlider.numberOfTickMarks = 6
        targetVolSlider.isContinuous = true; targetVolSlider.target = self; targetVolSlider.action = #selector(tvChg(_:))
        targetVolSlider.isEnabled = app.actionMode == .volumeDown
        view.addSubview(targetVolSlider)
        targetVolLabel = lbl(iW-20, y+2, 36, 14, "\(Int(app.targetVolume*100))%",
            .monospacedDigitSystemFont(ofSize: 10, weight: .medium), .tertiaryLabelColor, .right)
        view.addSubview(targetVolLabel)

        y -= 8; addSep(y)

        // Detection
        y -= 16; view.addSubview(sec(P, y, "DETECTION"))

        y -= 14
        view.addSubview(lbl(P, y, 80, 12, "🗣 Speech", .systemFont(ofSize: 10, weight: .semibold), .secondaryLabelColor))
        speechVal = lbl(P, y, iW, 12, "\(Int(app.sensitivity*100))%",
            .monospacedDigitSystemFont(ofSize: 10, weight: .medium), .tertiaryLabelColor, .right)
        view.addSubview(speechVal)

        y -= 20
        speechMeter = MeterSlider(frame: NSRect(x: P, y: y, width: iW, height: 16))
        speechMeter.threshold = CGFloat(app.sensitivity); speechMeter.barColor = .systemCyan
        speechMeter.onChange = { [weak self] v in
            self?.app.sensitivity = v; self?.speechVal.stringValue = "\(Int(v*100))%"
        }
        view.addSubview(speechMeter)

        y -= 18
        view.addSubview(lbl(P, y, 80, 12, "🔊 Volume", .systemFont(ofSize: 10, weight: .semibold), .secondaryLabelColor))
        volumeVal = lbl(P, y, iW, 12, app.volumeThreshold < 0.005 ? "OFF" : "\(Int(app.volumeThreshold*100))%",
            .monospacedDigitSystemFont(ofSize: 10, weight: .medium), .tertiaryLabelColor, .right)
        view.addSubview(volumeVal)

        y -= 20
        volumeMeter = MeterSlider(frame: NSRect(x: P, y: y, width: iW, height: 16))
        volumeMeter.threshold = CGFloat(app.volumeThreshold); volumeMeter.barColor = .systemBlue
        volumeMeter.onChange = { [weak self] v in
            self?.app.volumeThreshold = v
            self?.volumeVal.stringValue = v < 0.005 ? "OFF" : "\(Int(v*100))%"
        }
        view.addSubview(volumeMeter)

        y -= 8; addSep(y)

        // Resume
        y -= 16; view.addSubview(sec(P, y, "AUTO RESUME"))
        y -= 22
        view.addSubview(lbl(P, y+2, 42, 14, "Delay", .systemFont(ofSize: 10, weight: .medium), .secondaryLabelColor))
        let ds = NSSlider(frame: NSRect(x: P+44, y: y, width: iW-88, height: 18))
        ds.minValue = 0; ds.maxValue = 15; ds.integerValue = Int(app.resumeDelay)
        ds.controlSize = .small; ds.numberOfTickMarks = 16; ds.isContinuous = true
        ds.target = self; ds.action = #selector(delayChg(_:))
        view.addSubview(ds)
        delayLabel = lbl(iW-20, y+2, 36, 14, app.resumeDelay < 1 ? "Never" : "\(Int(app.resumeDelay))s",
            .monospacedDigitSystemFont(ofSize: 10, weight: .medium), .tertiaryLabelColor, .right)
        view.addSubview(delayLabel)

        y -= 8; addSep(y)

        // Options
        y -= 16; view.addSubview(sec(P, y, "OPTIONS"))
        y -= 22
        let meterTog = NSButton(frame: NSRect(x: P, y: y, width: iW/2, height: 18))
        meterTog.setButtonType(.switch); meterTog.title = " Show Meter"
        meterTog.font = .systemFont(ofSize: 11)
        meterTog.state = app.showMeter ? .on : .off
        meterTog.target = self; meterTog.action = #selector(togMeter(_:))
        view.addSubview(meterTog)

        let loginTog = NSButton(frame: NSRect(x: P + iW/2, y: y, width: iW/2, height: 18))
        loginTog.setButtonType(.switch); loginTog.title = " Launch at Login"
        loginTog.font = .systemFont(ofSize: 11)
        loginTog.state = isLaunchAtLoginEnabled() ? .on : .off
        loginTog.target = self; loginTog.action = #selector(togLaunchAtLogin(_:))
        view.addSubview(loginTog)

        y -= 12; addSep(y)

        // Bottom: Version + Update + Quit
        y -= 22
        let verStr = "v\(kAppVersion)"
        versionLabel = lbl(P, y+2, 80, 14, verStr, .systemFont(ofSize: 10), .tertiaryLabelColor)
        view.addSubview(versionLabel)

        updateBtn = NSButton(frame: NSRect(x: P+82, y: y, width: 80, height: 20))
        updateBtn.title = "Update"; updateBtn.bezelStyle = .rounded; updateBtn.controlSize = .small
        updateBtn.font = .systemFont(ofSize: 10, weight: .medium)
        updateBtn.contentTintColor = .systemGreen
        updateBtn.target = self; updateBtn.action = #selector(doUpdate)
        updateBtn.isHidden = true
        view.addSubview(updateBtn)

        let q = NSButton(frame: NSRect(x: W - P - 50, y: y, width: 50, height: 20))
        q.title = "Quit"; q.bezelStyle = .rounded; q.controlSize = .small
        q.font = .systemFont(ofSize: 11); q.target = self; q.action = #selector(quit)
        view.addSubview(q)

        startTimer()
    }

    func startTimer() {
        var permCheckCounter = 0
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let s = self, let a = s.app else { return }
            s.speechMeter?.update(level: CGFloat(a.soundDetector.currentSpeechConfidence), threshold: CGFloat(a.sensitivity))
            s.volumeMeter?.update(level: CGFloat(a.soundDetector.currentVolumeLevel), threshold: CGFloat(a.volumeThreshold))
            // live countdown for resume timer
            if let fire = a.resumeFireTime {
                let rem = max(0, fire.timeIntervalSinceNow)
                if rem > 0 {
                    s.statusLabel?.stringValue = String(format: "Resume in %.1fs…", rem)
                    s.statusLabel?.textColor = .secondaryLabelColor
                }
            }
            // check permissions every ~2s
            permCheckCounter += 1
            if permCheckCounter >= 20 {
                permCheckCounter = 0; s.checkPermissionBanners()
                // update version label if update available
                if a.updateChecker.isUpdateAvailable, let rel = a.updateChecker.latestRelease {
                    s.versionLabel?.stringValue = "v\(kAppVersion) → v\(rel.version)"
                    s.updateBtn?.isHidden = false
                }
            }
        }
        RunLoop.main.add(t, forMode: .common); timer = t
    }

    func checkPermissionBanners() {
        if let b = micBanner, !b.isHidden, isMicGranted() {
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; b.animator().alphaValue = 0 }
                completionHandler: { [weak b] in b?.isHidden = true }
        }
        if let b = axBanner, !b.isHidden, isAccessibilityGranted() {
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; b.animator().alphaValue = 0 }
                completionHandler: { [weak b] in b?.isHidden = true }
        }
    }

    func refreshStatus(text: String = "Listening…", color: NSColor = .secondaryLabelColor) {
        statusLabel?.stringValue = text; statusLabel?.textColor = color
    }

    @objc func togEnable(_ s: NSButton) {
        app.isEnabled = s.state == .on; app.saveEnabled()
        if app.isEnabled { app.soundDetector.start() }
        else { app.soundDetector.stop(); app.restoreMedia() }
        app.updateIcon(speaking: false)
        let (t, c) = app.currentStatusText(); refreshStatus(text: t, color: c)
    }

    @objc func togLaunchAtLogin(_ s: NSButton) {
        setLaunchAtLogin(s.state == .on)
        s.state = isLaunchAtLoginEnabled() ? .on : .off
    }

    @objc func micPick(_ s: NSPopUpButton) {
        guard let uid = s.selectedItem?.representedObject as? String else { return }
        setDefaultInputDevice(uid: uid)
        let gain = app.soundDetector.micGain
        app.soundDetector.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.app.soundDetector.micGain = gain
            self?.app.soundDetector.start()
        }
    }

    func populateMicList() {
        micPopup.removeAllItems()
        let devs = getInputDevices(); let cur = getDefaultInputUID()
        for (n, u) in devs {
            micPopup.addItem(withTitle: n); micPopup.lastItem?.representedObject = u
            if u == cur { micPopup.select(micPopup.lastItem) }
        }
    }

    func reloadMicList() { populateMicList() }

    @objc func actPick(_ s: NSButton) {
        app.restoreMedia()
        app.actionMode = ActionMode(rawValue: s.tag) ?? .pauseMedia
        targetVolSlider?.isEnabled = app.actionMode == .volumeDown
    }

    @objc func tvChg(_ s: NSSlider) {
        app.targetVolume = Float(s.integerValue)/100.0
        targetVolLabel?.stringValue = "\(s.integerValue)%"
    }

    @objc func delayChg(_ s: NSSlider) {
        app.resumeDelay = TimeInterval(s.integerValue)
        delayLabel?.stringValue = s.integerValue == 0 ? "Never" : "\(s.integerValue)s"
    }

    @objc func togMeter(_ s: NSButton) {
        app.showMeter = s.state == .on
        app.redrawStatusIcon()
    }

    @objc func doUpdate() {
        updateBtn.isEnabled = false; updateBtn.title = "Downloading…"
        app.updateChecker.downloadAndInstall()
    }

    @objc func quit() {
        // Sync restore without subprocess: just send play/pause if we paused, restore volume
        if app.isPausedByUs { sendMediaPlayPause(); app.isPausedByUs = false }
        if app.isVolumeDownByUs { setSystemVolume(app.savedVolume); app.isVolumeDownByUs = false }
        app.resumeTimer?.invalidate(); app.resumeTimer = nil
        app.soundDetector.stop(); NSApplication.shared.terminate(nil)
    }

    func lbl(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ t: String,
             _ f: NSFont, _ c: NSColor = .controlTextColor, _ a: NSTextAlignment = .left) -> NSTextField {
        let l = NSTextField(frame: NSRect(x: x, y: y, width: w, height: h))
        l.stringValue = t; l.isEditable = false; l.isBordered = false; l.drawsBackground = false
        l.font = f; l.textColor = c; l.alignment = a; return l
    }
    func sec(_ x: CGFloat, _ y: CGFloat, _ t: String) -> NSTextField {
        lbl(x, y, 200, 12, t, .systemFont(ofSize: 9, weight: .heavy), .tertiaryLabelColor)
    }
    func addSep(_ y: CGFloat) {
        let s = NSBox(frame: NSRect(x: 16, y: y, width: 268, height: 1))
        s.boxType = .separator; view.addSubview(s)
    }
    deinit { timer?.invalidate() }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Sound Detector
// ═══════════════════════════════════════════════════════════

protocol SoundDetectorDelegate: AnyObject {
    func soundDetector(_ d: SoundDetector, didDetectSpeech label: String, confidence: Float)
    func soundDetector(_ d: SoundDetector, didDetectSilence topSound: String)
}

class SoundDetector: NSObject {
    weak var delegate: SoundDetectorDelegate?
    var micGain: Float = 20.0

    private var _sc: Float = 0, _vl: Float = 0
    private let lock = NSLock()
    var currentSpeechConfidence: Float {
        get { lock.lock(); defer { lock.unlock() }; return _sc }
        set { lock.lock(); _sc = newValue; lock.unlock() }
    }
    var currentVolumeLevel: Float {
        get { lock.lock(); defer { lock.unlock() }; return _vl }
        set { lock.lock(); _vl = newValue; lock.unlock() }
    }

    private var audioEngine = AVAudioEngine()
    private var streamAnalyzer: SNAudioStreamAnalyzer?
    private let analysisQueue = DispatchQueue(label: "com.imhear.analysis")
    private(set) var isRunning = false

    private let speechIds: Set<String> = [
        "speech","shout","yell","whispering","laughter",
        "children_shouting","conversation","narration","babble"
    ]
    private let labels: [String:String] = [
        "speech":"Speech","shout":"Shout","yell":"Yell","whispering":"Whisper",
        "laughter":"Laugh","children_shouting":"Children","conversation":"Talk",
        "narration":"Narration","babble":"Babble"
    ]

    func start() {
        guard !isRunning else { return }
        audioEngine = AVAudioEngine()
        let node = audioEngine.inputNode
        let fmt = node.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else { return }

        streamAnalyzer = SNAudioStreamAnalyzer(format: fmt)
        do {
            let req = try SNClassifySoundRequest(classifierIdentifier: .version1)
            req.windowDuration = CMTimeMakeWithSeconds(0.5, preferredTimescale: 48_000)
            req.overlapFactor = 0.5
            try streamAnalyzer?.add(req, withObserver: self)
        } catch { return }

        node.installTap(onBus: 0, bufferSize: 8192, format: fmt) { [weak self] buf, time in
            guard let self = self else { return }
            if let ch = buf.floatChannelData?[0] {
                let n = Int(buf.frameLength); var s: Float = 0
                for i in 0..<n { s += ch[i]*ch[i] }
                self.currentVolumeLevel = min(sqrt(s/Float(n)) * self.micGain, 1.0)
            }
            self.analysisQueue.async { self.streamAnalyzer?.analyze(buf, atAudioFramePosition: time.sampleTime) }
        }
        do { try audioEngine.start(); isRunning = true } catch { }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        // Drain analysis queue so no pending analyze() is using the analyzer
        analysisQueue.sync {}
        streamAnalyzer = nil
    }
}

extension SoundDetector: SNResultsObserving {
    func request(_ req: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let sp = r.classifications.filter { speechIds.contains($0.identifier) }
        let top = sp.max(by: { $0.confidence < $1.confidence })
        currentSpeechConfidence = Float(top?.confidence ?? 0)
        if let s = top, s.confidence > 0.15 {
            delegate?.soundDetector(self, didDetectSpeech: labels[s.identifier] ?? s.identifier, confidence: Float(s.confidence))
        } else {
            delegate?.soundDetector(self, didDetectSilence: r.classifications.first?.identifier ?? "silence")
        }
    }
    func request(_ r: SNRequest, didFailWithError e: Error) {}
}

// ═══════════════════════════════════════════════════════════
// MARK: - Entry
// ═══════════════════════════════════════════════════════════

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
