import Foundation
import Combine
import UIKit
import CoreLocation
import CoreMotion
import AVFoundation

/// Background keep-alive controller.
///
/// Tier ladder: `省电` < `均衡` < `强力`.
///   - `省电`: nothing at all. No location request, no monitoring, no timer.
///   - `均衡`: significant-location-change + visit monitoring + one 150 m exit fence.
///   - `强力`: balanced + silent PCM audio loop + pedometer + motion state.
///
/// `均衡` and `强力` need the "Always" location authorization because region and
/// visit monitoring are unavailable with "While Using". A refused upgrade or a
/// denied authorization demotes the requested tier to `省电` and reports through
/// `onFallback`.
///
/// Coordinates are kept in memory only (they anchor the fence circle) and are
/// never written to disk.
@MainActor
final class KeepAliveController: NSObject, ObservableObject, CLLocationManagerDelegate {

    // MARK: - Tiers

    static let tierPowerSaving = "省电"
    static let tierBalanced = "均衡"
    static let tierStrong = "强力"

    // MARK: - Event sources

    static let sourceLocation = "位置"
    static let sourceVisit = "到访"
    static let sourceFence = "围栏"
    static let sourceSteps = "步数"
    static let sourceMotion = "运动状态"
    static let sourceTimer = "定时"

    // MARK: - Published state

    @Published var locationStatus: String = "未启用"
    @Published var audioRunning: Bool = false
    @Published var effectiveTier = "自动同步已关闭"

    /// Fired for every keep-alive trigger with one of the source constants above.
    var onEvent: ((String) -> Void)?
    /// Fired when a requested tier is demoted to `省电`.
    var onFallback: ((String) -> Void)?
    /// Optional richer payload: source + human readable detail.
    var onEventDetail: ((String, String) -> Void)?

    static let shared = KeepAliveController()

    // MARK: - Private state

    private let locationManager = CLLocationManager()
    private let activityManager = CMMotionActivityManager()
    private let pedometer = CMPedometer()
    private let audio = SilentAudioLoop()

    private var desiredTier: String = KeepAliveController.tierPowerSaving
    private var activeTier: String = KeepAliveController.tierPowerSaving
    private var enabled = false
    private var intervalMinutes = 15
    private var stepThreshold = 100

    private var timer: Timer?
    private var alwaysUpgradeRequested = false
    private var motionRunning = false
    private var fenceInstalled = false
    private var appliedSignature: String?
    private var appliedEnabled = false
    /// Last known coordinate, in memory only. Never persisted.
    private var lastCoordinate: CLLocationCoordinate2D?
    private var stepBaseline: Double?
    private var lastMotionState: String?

    private static let fenceRadius: CLLocationDistance = 150
    private static let fenceIdentifier = "dev.mnemo.keepalive.fence"
    private static let tierKey = "dev.mnemo.keepalive.tier"
    private static let enabledKey = "dev.mnemo.keepalive.enabled"
    private static let intervalKey = "dev.mnemo.keepalive.intervalMinutes"
    private static let stepsKey = "dev.mnemo.keepalive.stepThreshold"

    nonisolated static var stepsAvailable: Bool { CMPedometer.isStepCountingAvailable() }

    private override init() {
        super.init()
        locationManager.delegate = self
        locationManager.activityType = .other
        locationManager.pausesLocationUpdatesAutomatically = false
        audio.onStateChange = { [weak self] running in
            guard let self else { return }
            self.audioRunning = running
            if self.enabled, self.activeTier == Self.tierStrong {
                self.effectiveTier = running ? Self.tierStrong : Self.tierBalanced
            }
            self.syncTimerWithAudio()
        }
    }

    // MARK: - Public API

    /// Apply a keep-alive tier. `tier` is one of `省电` / `均衡` / `强力`.
    func apply(tier: String, enabled: Bool, intervalMinutes: Int, stepThreshold: Int) {
        let normalized = Self.normalizeTier(tier)
        let interval = max(1, min(1440, intervalMinutes))
        let threshold = max(1, stepThreshold)
        let signature = "\(normalized)|\(interval)|\(threshold)"
        let changed = signature != appliedSignature || enabled != appliedEnabled

        desiredTier = normalized
        self.enabled = enabled
        self.intervalMinutes = interval
        self.stepThreshold = threshold
        if changed { stopTimer() }

        guard enabled else {
            appliedSignature = nil
            appliedEnabled = false
            persist()
            stopEverything()
            refreshStatus()
            return
        }

        persist()
        guard changed else {
            // Same configuration: keep the running audio, the step counter and the timer.
            refreshStatus()
            return
        }
        appliedSignature = signature
        appliedEnabled = true
        reconcile()
    }

    /// Re-arm the keep-alive after a cold start or a location-triggered relaunch.
    func restoreLocationLaunch() {
        let defaults = UserDefaults.standard
        guard let tier = defaults.string(forKey: Self.tierKey) else {
            refreshStatus()
            return
        }
        let interval = defaults.integer(forKey: Self.intervalKey)
        let steps = defaults.integer(forKey: Self.stepsKey)
        appliedSignature = nil
        appliedEnabled = false
        apply(tier: tier,
              enabled: defaults.bool(forKey: Self.enabledKey),
              intervalMinutes: interval > 0 ? interval : 15,
              stepThreshold: steps > 0 ? steps : 100)
    }

    /// Recompute the human readable location status.
    func refreshStatus() {
        locationStatus = Self.statusText(enabled: enabled,
                                         desired: desiredTier,
                                         active: activeTier,
                                         authorization: locationManager.authorizationStatus,
                                         alwaysUpgradeRequested: alwaysUpgradeRequested,
                                         fenceInstalled: fenceInstalled)
    }

    // MARK: - Tier reconciliation

    private func reconcile() {
        guard desiredTier != Self.tierPowerSaving else {
            // 省电 keeps everything off: no location request, no monitoring, no timer.
            stopEverything()
            return
        }
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationStatus = "等待定位授权"
            requestWhenInUse()
        case .authorizedAlways:
            activate(desiredTier)
        case .authorizedWhenInUse:
            if alwaysUpgradeRequested {
                locationStatus = "仅「使用 App 时」定位：请到系统设置中开启「始终允许」"
            } else {
                requestAlwaysUpgrade()
            }
        case .denied:
            fallBackToPowerSaving("定位权限被拒绝")
        case .restricted:
            fallBackToPowerSaving("定位权限受系统限制")
        @unknown default:
            fallBackToPowerSaving("未知的定位权限状态")
        }
        refreshStatus()
    }

    private func activate(_ tier: String) {
        activeTier = tier
        effectiveTier = tier
        configureLocation(for: tier)
        if tier == Self.tierStrong { startStrongFeatures() } else { stopStrongFeatures() }
        syncTimerWithAudio()
        refreshStatus()
    }

    /// Demote to `省电`: no location, no monitoring, no timer, no audio.
    private func fallBackToPowerSaving(_ reason: String) {
        let demoted = desiredTier != Self.tierPowerSaving
        desiredTier = Self.tierPowerSaving
        alwaysUpgradeRequested = false
        appliedSignature = nil
        appliedEnabled = false
        persist()
        stopEverything()
        if demoted {
            onFallback?("定位权限不足，已回退到省电模式（\(reason)）")
        }
        refreshStatus()
    }

    private func requestWhenInUse() {
        guard Self.usageDescription("NSLocationWhenInUseUsageDescription") != nil else {
            if desiredTier != Self.tierPowerSaving {
                fallBackToPowerSaving("Info.plist 缺少 NSLocationWhenInUseUsageDescription")
            } else {
                locationStatus = "Info.plist 缺少 NSLocationWhenInUseUsageDescription"
            }
            return
        }
        locationManager.requestWhenInUseAuthorization()
    }

    /// Ask for the Always upgrade. A refusal comes back through the delegate.
    private func requestAlwaysUpgrade() {
        guard Self.usageDescription("NSLocationAlwaysAndWhenInUseUsageDescription") != nil else {
            fallBackToPowerSaving("Info.plist 缺少 NSLocationAlwaysAndWhenInUseUsageDescription")
            return
        }
        alwaysUpgradeRequested = true
        locationManager.requestAlwaysAuthorization()
    }

    // MARK: - Location

    private func configureLocation(for tier: String) {
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopMonitoringVisits()
        fenceInstalled = false

        let always = locationManager.authorizationStatus == .authorizedAlways
        guard always else { return }

        locationManager.desiredAccuracy = tier == Self.tierPowerSaving
            ? kCLLocationAccuracyKilometer
            : kCLLocationAccuracyHundredMeters
        locationManager.distanceFilter = tier == Self.tierPowerSaving ? 500 : 100

        // Setting this without the location background mode traps at runtime.
        if Self.backgroundModes.contains("location") {
            locationManager.allowsBackgroundLocationUpdates = true
            locationManager.showsBackgroundLocationIndicator = false
        }

        locationManager.startMonitoringSignificantLocationChanges()
        locationManager.startMonitoringVisits()

        if let coordinate = lastCoordinate {
            installFence(center: coordinate)
        } else {
            locationManager.requestLocation()
        }
    }

    private func installFence(center: CLLocationCoordinate2D) {
        removeFence()
        let region = CLCircularRegion(center: center, radius: Self.fenceRadius, identifier: Self.fenceIdentifier)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        fenceInstalled = true
        locationManager.startMonitoring(for: region)
    }

    private func removeFence() {
        for region in locationManager.monitoredRegions where region.identifier == Self.fenceIdentifier {
            locationManager.stopMonitoring(for: region)
        }
        fenceInstalled = false
    }

    private func handleLocation(_ coordinate: CLLocationCoordinate2D?) {
        guard enabled, activeTier != Self.tierPowerSaving, let coordinate else { return }
        lastCoordinate = coordinate
        if activeTier != Self.tierPowerSaving, locationManager.authorizationStatus == .authorizedAlways {
            installFence(center: coordinate)
        }
        emit(Self.sourceLocation, detail: "位置更新")
    }

    private func handleVisit(coordinate: CLLocationCoordinate2D) {
        guard enabled, activeTier != Self.tierPowerSaving else { return }
        lastCoordinate = coordinate
        if activeTier != Self.tierPowerSaving {
            installFence(center: coordinate)
        }
        emit(Self.sourceVisit, detail: "到访")
    }

    private func handleExit(identifier: String) {
        guard enabled, activeTier != Self.tierPowerSaving, identifier == Self.fenceIdentifier else { return }
        emit(Self.sourceFence, detail: "离开 150m 围栏")
        removeFence()
        locationManager.requestLocation()
    }

    private func handleLocationFailure(_ message: String) {
        locationStatus = "定位失败：" + message
        // Keep the fence alive from the last known coordinate.
        if let coordinate = lastCoordinate, activeTier != Self.tierPowerSaving {
            installFence(center: coordinate)
        }
    }

    // MARK: - Strong tier: steps and motion

    private func startStrongFeatures() {
        audio.start()
        startMotion()
    }

    private func stopStrongFeatures() {
        audio.stop()
        stopMotion()
        stepBaseline = nil
        lastMotionState = nil
    }

    private func startMotion() {
        guard !motionRunning else { return }
        guard Self.usageDescription("NSMotionUsageDescription") != nil else {
            locationStatus = "Info.plist 缺少 NSMotionUsageDescription，步数与运动状态不可用"
            return
        }
        if CMMotionActivityManager.isActivityAvailable() {
            activityManager.startActivityUpdates(to: .main) { [weak self] activity in
                guard let activity else { return }
                let state = Self.motionState(activity)
                Task { @MainActor [weak self] in self?.handleMotion(state: state) }
            }
        }
        if CMPedometer.isStepCountingAvailable() {
            stepBaseline = 0
            pedometer.startUpdates(from: Date()) { [weak self] data, _ in
                guard let data else { return }
                let steps = data.numberOfSteps.doubleValue
                Task { @MainActor [weak self] in self?.handleSteps(steps) }
            }
        }
        motionRunning = true
    }

    private func stopMotion() {
        pedometer.stopUpdates()
        activityManager.stopActivityUpdates()
        motionRunning = false
    }

    private func handleSteps(_ total: Double) {
        guard enabled, activeTier == Self.tierStrong else { return }
        guard let baseline = stepBaseline else {
            stepBaseline = total
            return
        }
        let delta = total - baseline
        guard delta >= Double(stepThreshold) else { return }
        stepBaseline = total
        emit(Self.sourceSteps, detail: "新增 \(Int(delta)) 步")
    }

    /// Only a stationary to moving transition is worth reporting.
    private func handleMotion(state: String) {
        guard enabled, activeTier == Self.tierStrong else { return }
        let previous = lastMotionState
        lastMotionState = state
        guard previous == "静止", ["行走", "跑步", "骑行", "驾车"].contains(state) else { return }
        emit(Self.sourceMotion, detail: state)
    }

    nonisolated private static func motionState(_ activity: CMMotionActivity) -> String {
        if activity.running { return "跑步" }
        if activity.walking { return "行走" }
        if activity.automotive { return "驾车" }
        if activity.cycling { return "骑行" }
        if activity.stationary { return "静止" }
        return "未知"
    }

    // MARK: - Timer

    /// The timer only runs in `强力`, and only while the silent audio is playing.
    private func syncTimerWithAudio() {
        let shouldRun = enabled
            && desiredTier == Self.tierStrong
            && activeTier == Self.tierStrong
            && audioRunning
        if shouldRun {
            if timer == nil { startTimer() }
        } else {
            stopTimer()
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let seconds = TimeInterval(max(1, min(1440, intervalMinutes)) * 60)
        let tick = Timer(timeInterval: seconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.emit(Self.sourceTimer, detail: "间隔 \(self.intervalMinutes) 分钟")
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Lifecycle

    private func stopEverything() {
        locationManager.stopMonitoringSignificantLocationChanges()
        locationManager.stopMonitoringVisits()
        removeFence()
        locationManager.stopUpdatingLocation()
        stopStrongFeatures()
        stopTimer()
        lastCoordinate = nil
        activeTier = Self.tierPowerSaving
        effectiveTier = enabled ? Self.tierPowerSaving : "自动同步已关闭"
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(desiredTier, forKey: Self.tierKey)
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(intervalMinutes, forKey: Self.intervalKey)
        defaults.set(stepThreshold, forKey: Self.stepsKey)
    }

    private func emit(_ source: String, detail: String) {
        onEvent?(source)
        onEventDetail?(source, detail)
    }

    // MARK: - Helpers

    private static func normalizeTier(_ tier: String) -> String {
        switch tier {
        case tierStrong: return tierStrong
        case tierBalanced: return tierBalanced
        default: return tierPowerSaving
        }
    }

    private static func usageDescription(_ key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static var backgroundModes: [String] {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]) ?? []
    }

    private static func statusText(enabled: Bool,
                                  desired: String,
                                  active: String,
                                  authorization: CLAuthorizationStatus,
                                  alwaysUpgradeRequested: Bool,
                                  fenceInstalled: Bool) -> String {
        guard enabled else { return "未启用" }
        guard desired != tierPowerSaving else {
            switch authorization {
            case .authorizedAlways: return "始终允许（省电档未监听）"
            case .authorizedWhenInUse: return "使用期间允许（省电档未监听）"
            case .denied: return "已拒绝（省电档未监听）"
            case .restricted: return "受限制（省电档未监听）"
            default: return "未授权（省电档未监听）"
            }
        }
        var parts: [String] = []
        switch authorization {
        case .notDetermined: parts.append("等待定位授权")
        case .restricted: parts.append("定位受系统限制")
        case .denied: parts.append("定位权限被拒绝")
        case .authorizedWhenInUse:
            parts.append(alwaysUpgradeRequested ? "仅「使用 App 时」定位，请到系统设置开启「始终允许」" : "仅「使用 App 时」定位")
        case .authorizedAlways: parts.append("已允许「始终」定位")
        @unknown default: parts.append("定位状态未知")
        }
        switch active {
        case tierBalanced:
            parts.append(fenceInstalled ? "位置 + 到访 + 150m 围栏" : "位置 + 到访 + 围栏待首次定位")
        case tierStrong:
            parts.append(fenceInstalled ? "位置 + 到访 + 150m 围栏 + 静音音频 + 步数" : "位置 + 到访 + 围栏待首次定位 + 静音音频 + 步数")
        default:
            parts.append("增强保活尚未启用")
        }
        if desired != active { parts.append("已从「\(desired)」回退") }
        if !backgroundModes.contains("location") { parts.append("缺后台定位模式") }
        if active == tierStrong {
            if !backgroundModes.contains("audio") { parts.append("缺后台音频模式") }
            if usageDescription("NSMotionUsageDescription") == nil { parts.append("缺运动权限说明") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in self?.handleAuthorization(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let coordinate = locations.last?.coordinate
        Task { @MainActor [weak self] in self?.handleLocation(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let coordinate = visit.coordinate
        Task { @MainActor [weak self] in self?.handleVisit(coordinate: coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        let identifier = region.identifier
        Task { @MainActor [weak self] in self?.handleExit(identifier: identifier) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        let denied = (error as NSError).code == CLError.Code.denied.rawValue
        let message = "系统错误码 \((error as NSError).code)"
        Task { @MainActor [weak self] in
            guard let self else { return }
            if denied {
                self.fallBackToPowerSaving("围栏监控被系统拒绝")
            } else {
                self.locationStatus = "围栏监控失败：" + message
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let message = "系统错误码 \((error as NSError).code)"
        Task { @MainActor [weak self] in self?.handleLocationFailure(message) }
    }

    // MARK: - Authorization handling

    private func handleAuthorization(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            alwaysUpgradeRequested = false
            if enabled, desiredTier != Self.tierPowerSaving { activate(desiredTier) }
        case .authorizedWhenInUse:
            if alwaysUpgradeRequested {
                // The Always prompt came back without Always: an explicit refusal.
                alwaysUpgradeRequested = false
                if enabled { fallBackToPowerSaving("未授予「始终允许」定位权限") }
            } else if enabled, desiredTier != Self.tierPowerSaving {
                requestAlwaysUpgrade()
            }
        case .denied:
            alwaysUpgradeRequested = false
            if enabled { fallBackToPowerSaving("定位权限被拒绝") }
        case .restricted:
            alwaysUpgradeRequested = false
            if enabled { fallBackToPowerSaving("定位权限受系统限制") }
        case .notDetermined:
            break
        @unknown default:
            break
        }
        refreshStatus()
    }
}

/// Silent looping PCM player that keeps the process alive in the `强力` tier.
///
/// The buffer is generated in memory (PCM 16 bit mono WAV, all zero samples,
/// player volume 0) so no file is ever written. Interruptions, route changes
/// and media service resets restart the loop.
@MainActor
private final class SilentAudioLoop: NSObject {
    var onStateChange: (@MainActor (Bool) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var player: AVAudioPlayer?
    private var observers: [NSObjectProtocol] = []
    private var requested = false

    func start() {
        requested = true
        guard player == nil else { return }
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            guard let data = Self.silentPCMData() else {
                onStateChange?(false)
                return
            }
            let player = try AVAudioPlayer(data: data)
            player.numberOfLoops = -1
            player.volume = 0
            guard player.prepareToPlay(), player.play() else {
                onStateChange?(false)
                return
            }
            self.player = player
            installObservers()
            onStateChange?(true)
        } catch {
            onStateChange?(false)
        }
    }

    func stop() {
        requested = false
        player?.stop()
        player = nil
        removeObservers()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        onStateChange?(false)
    }

    private func resume() {
        guard requested, player != nil else { return }
        try? session.setActive(true)
        player?.play()
        onStateChange?(player?.isPlaying ?? false)
    }

    // MARK: - Notifications

    private func installObservers() {
        removeObservers()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap { AVAudioSession.InterruptionType(rawValue: $0) }
            Task { @MainActor [weak self] in self?.handleInterruption(type: type) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap { AVAudioSession.RouteChangeReason(rawValue: $0) }
            Task { @MainActor [weak self] in self?.handleRouteChange(reason: reason) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMediaReset() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.resume() }
        })
    }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType?) {
        guard let type else { return }
        switch type {
        case .began:
            player?.pause()
            onStateChange?(false)
        case .ended:
            resume()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason: AVAudioSession.RouteChangeReason?) {
        if reason == .oldDeviceUnavailable { resume() }
    }

    private func handleMediaReset() {
        guard requested else { return }
        player = nil
        start()
    }

    // MARK: - PCM generation

    /// 2 s of 16 bit mono PCM at 22.05 kHz. All samples are zero.
    private static func silentPCMData() -> Data? {
        let sampleRate = 22050
        let frames = sampleRate * 2
        let samples = [Int16](repeating: 0, count: frames)
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36 + frames * 2), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt16(1), to: &data)
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(sampleRate * 2), to: &data)
        appendLittleEndian(UInt16(2), to: &data)
        appendLittleEndian(UInt16(16), to: &data)
        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(UInt32(frames * 2), to: &data)
        samples.withUnsafeBytes { raw in
            data.append(contentsOf: raw)
        }
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
