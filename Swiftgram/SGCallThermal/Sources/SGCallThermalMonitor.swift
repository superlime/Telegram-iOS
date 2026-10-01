import Foundation
import UIKit
import SwiftSignalKit
import SGSimpleSettings
import SGLogging

// MARK: Swiftgram - cooler video calls
//
// Watches the device's thermal condition for the length of a call, combines the
// user's call-video settings with an automatic step-down when iOS reports heat,
// and hands the resulting limits to the call's video pipeline.
//
// The limits themselves are applied natively (SGCallVideoLimits in TgVoipWebrtc):
// capture format and frame rate in the vendored VideoCameraCapturer, the
// adapter request and the encoder bitrate in the vendored DarwinInterface. This
// module only decides the numbers, so it has no dependency on the call stack;
// the caller passes a closure that forwards them.

private let logTag = "SGThermal"

public enum SGThermalLevel: Int, Comparable, CustomStringConvertible {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .critical
        }
    }

    public static func < (lhs: SGThermalLevel, rhs: SGThermalLevel) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    public var description: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }
}

/// Ceilings for the outgoing call video. 0 means "no limit" for that field.
public struct SGCallVideoLimitValues: Equatable, CustomStringConvertible {
    public var maxShortSide: Int32
    public var maxFps: Int32
    public var maxBitrateKbps: Int32

    public init(maxShortSide: Int32, maxFps: Int32, maxBitrateKbps: Int32) {
        self.maxShortSide = maxShortSide
        self.maxFps = maxFps
        self.maxBitrateKbps = maxBitrateKbps
    }

    public static let unlimited = SGCallVideoLimitValues(maxShortSide: 0, maxFps: 0, maxBitrateKbps: 0)

    /// Per field, the stricter of the two.
    public func combined(with other: SGCallVideoLimitValues) -> SGCallVideoLimitValues {
        func stricter(_ a: Int32, _ b: Int32) -> Int32 {
            if a == 0 { return b }
            if b == 0 { return a }
            return min(a, b)
        }
        return SGCallVideoLimitValues(
            maxShortSide: stricter(self.maxShortSide, other.maxShortSide),
            maxFps: stricter(self.maxFps, other.maxFps),
            maxBitrateKbps: stricter(self.maxBitrateKbps, other.maxBitrateKbps)
        )
    }

    /// Short form for logs and the call screen, e.g. "480p · 15fps · 400k".
    /// Unlimited fields show the stock values (720p, 30fps, 1000k).
    public func shortText(separator: String = " · ") -> String {
        let resolution = self.maxShortSide > 0 ? "\(self.maxShortSide)p" : "720p"
        let fps = self.maxFps > 0 ? "\(self.maxFps)fps" : "30fps"
        let bitrate = self.maxBitrateKbps > 0 ? "\(self.maxBitrateKbps)k" : "1000k"
        return [resolution, fps, bitrate].joined(separator: separator)
    }

    public var description: String {
        return self.shortText(separator: "/")
    }
}

public enum SGThrottleTier: Int, Comparable, CustomStringConvertible {
    case serious = 1
    case critical = 2

    public static func < (lhs: SGThrottleTier, rhs: SGThrottleTier) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }

    /// The step-down applied on top of the user's settings.
    public var limits: SGCallVideoLimitValues {
        switch self {
        case .serious:
            return SGCallVideoLimitValues(maxShortSide: 480, maxFps: 15, maxBitrateKbps: 400)
        case .critical:
            return SGCallVideoLimitValues(maxShortSide: 360, maxFps: 12, maxBitrateKbps: 250)
        }
    }

    public var description: String {
        switch self {
        case .serious: return "serious"
        case .critical: return "critical"
        }
    }

    init?(level: SGThermalLevel) {
        switch level {
        case .nominal, .fair: return nil
        case .serious: self = .serious
        case .critical: self = .critical
        }
    }
}

public struct SGThrottleState: Equatable {
    public var tier: SGThrottleTier
    /// Effective limits while throttled (user settings combined with the tier).
    public var limits: SGCallVideoLimitValues
}

public struct SGThermalReading: Equatable {
    public var level: SGThermalLevel
    /// 0...1, or nil when iOS does not report it.
    public var batteryLevel: Float?
    /// Charging, or plugged in and full.
    public var isCharging: Bool
    /// Battery temperature, when the private probe works on this device.
    public var celsius: Double?
    /// Non-nil while auto-throttle is engaged.
    public var throttle: SGThrottleState?
    /// The limits currently applied to the outgoing video.
    public var limits: SGCallVideoLimitValues
}

public final class SGCallThermalMonitor {
    public static let shared = SGCallThermalMonitor()

    /// How often the battery, temperature and settings are re-read.
    private static let tickInterval: Double = 5.0
    /// How often a status line is written to the log during a call.
    private static let logInterval: Double = 30.0
    /// How long a cooler level has to hold before the throttle is relaxed.
    /// iOS thermal states already have some hysteresis; this stops the video
    /// flapping between qualities on the boundary.
    private static let releaseDelay: Double = 60.0

    private var activeCount = 0
    private var applyLimits: ((SGCallVideoLimitValues) -> Void)?
    private var timer: SwiftSignalKit.Timer?
    private var thermalObserver: NSObjectProtocol?
    private var batteryObservers: [NSObjectProtocol] = []

    private let probe = SGBatteryTemperatureProbe()

    private var startTime: Double = 0.0
    private var lastLogTime: Double = 0.0
    private var throttleTier: SGThrottleTier?
    private var coolerSince: Double?
    private var appliedLimits: SGCallVideoLimitValues?
    private var lastReading: SGThermalReading?

    private let readingPromise = ValuePromise<SGThermalReading?>(nil, ignoreRepeated: true)

    /// The latest reading while a call is running, nil otherwise. Delivered on
    /// the main queue.
    public var readings: Signal<SGThermalReading?, NoError> {
        return self.readingPromise.get()
    }

    private init() {
        self.probe.onFirstResult = { text in
            SGLogger.shared.log(logTag, "battery temperature probe: \(text)")
        }
    }

    /// Begin monitoring for a call. `applyLimits` is called on the main queue
    /// whenever the effective limits change, and with `.unlimited` on `stop()`.
    /// Must be called on the main queue. Calls are reference counted.
    public func start(applyLimits: @escaping (SGCallVideoLimitValues) -> Void) {
        assert(Thread.isMainThread)
        self.applyLimits = applyLimits
        self.activeCount += 1
        if self.activeCount > 1 {
            self.evaluate(reason: "call added")
            return
        }

        self.startTime = CFAbsoluteTimeGetCurrent()
        self.lastLogTime = 0.0
        self.throttleTier = nil
        self.coolerSince = nil
        self.appliedLimits = nil
        self.lastReading = nil

        UIDevice.current.isBatteryMonitoringEnabled = true

        self.thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.evaluate(reason: "thermal state changed")
        })
        self.batteryObservers = [
            NotificationCenter.default.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
                self?.evaluate(reason: "battery state changed")
            })
        ]

        let timer = SwiftSignalKit.Timer(timeout: SGCallThermalMonitor.tickInterval, repeat: true, completion: { [weak self] in
            self?.evaluate(reason: nil)
        }, queue: Queue.mainQueue())
        self.timer = timer
        timer.start()

        SGLogger.shared.log(logTag, "monitoring started; settings: \(self.userLimits()) autoThrottle=\(SGSimpleSettings.shared.callThermalAutoThrottle)")
        self.evaluate(reason: "call started")
    }

    /// End monitoring for a call. Must be called on the main queue.
    public func stop() {
        assert(Thread.isMainThread)
        if self.activeCount == 0 {
            return
        }
        self.activeCount -= 1
        if self.activeCount > 0 {
            return
        }

        if let lastReading = self.lastReading {
            SGLogger.shared.log(logTag, "monitoring stopped after \(self.elapsedText()); last: \(self.describe(lastReading))")
        }

        self.timer?.invalidate()
        self.timer = nil
        if let thermalObserver = self.thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
        for observer in self.batteryObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        self.batteryObservers = []

        self.applyLimits?(.unlimited)
        self.applyLimits = nil
        self.throttleTier = nil
        self.coolerSince = nil
        self.appliedLimits = nil
        self.lastReading = nil
        self.readingPromise.set(nil)
    }

    private func userLimits() -> SGCallVideoLimitValues {
        let settings = SGSimpleSettings.shared
        return SGCallVideoLimitValues(
            maxShortSide: settings.callVideoResolutionEnum.maxShortSide,
            maxFps: settings.callVideoFrameRateEnum.maxFps,
            maxBitrateKbps: settings.callVideoMaxBitrateEnum.maxKbps
        )
    }

    private func elapsedText() -> String {
        let elapsed = Int(max(0.0, CFAbsoluteTimeGetCurrent() - self.startTime))
        return String(format: "+%02d:%02d:%02d", elapsed / 3600, (elapsed / 60) % 60, elapsed % 60)
    }

    private func describe(_ reading: SGThermalReading) -> String {
        let temperature = reading.celsius.flatMap { String(format: "%.1fC", $0) } ?? "n/a"
        let battery = reading.batteryLevel.flatMap { "\(Int(($0 * 100.0).rounded()))%" } ?? "n/a"
        let throttle = reading.throttle.flatMap { "\($0.tier)" } ?? "off"
        return "level=\(reading.level) temp=\(temperature) battery=\(battery) charging=\(reading.isCharging ? "yes" : "no") throttle=\(throttle) limits=\(reading.limits)"
    }

    /// Update the throttle tier for the current level, with a delayed release.
    private func updateThrottle(level: SGThermalLevel, now: Double, userLimits: SGCallVideoLimitValues) {
        let desired: SGThrottleTier? = SGSimpleSettings.shared.callThermalAutoThrottle ? SGThrottleTier(level: level) : nil
        let current = self.throttleTier

        func limitsText(_ tier: SGThrottleTier?) -> String {
            if let tier {
                return "\(userLimits.combined(with: tier.limits))"
            } else {
                return "\(userLimits)"
            }
        }

        if desired == current {
            if self.coolerSince != nil {
                SGLogger.shared.log(logTag, "throttle release cancelled: level=\(level) is back at \(current.flatMap { "\($0)" } ?? "off")")
            }
            self.coolerSince = nil
            return
        }

        let isStricter: Bool
        switch (current, desired) {
        case (nil, .some):
            isStricter = true
        case let (.some(currentTier), .some(desiredTier)):
            isStricter = desiredTier > currentTier
        default:
            isStricter = false
        }

        if isStricter {
            let verb = current == nil ? "engaged" : "stepped down"
            SGLogger.shared.log(logTag, "throttle \(verb): level=\(level) \(limitsText(current)) -> \(limitsText(desired))")
            self.throttleTier = desired
            self.coolerSince = nil
            return
        }

        // Cooler than the current tier, or auto-throttle was switched off.
        if !SGSimpleSettings.shared.callThermalAutoThrottle {
            SGLogger.shared.log(logTag, "throttle released: auto-throttle turned off; \(limitsText(current)) -> \(limitsText(nil))")
            self.throttleTier = nil
            self.coolerSince = nil
            return
        }
        guard let coolerSince = self.coolerSince else {
            self.coolerSince = now
            SGLogger.shared.log(logTag, "throttle release held: level=\(level); relaxing to \(desired.flatMap { "\($0)" } ?? "off") if it holds for \(Int(SGCallThermalMonitor.releaseDelay))s")
            return
        }
        if now - coolerSince >= SGCallThermalMonitor.releaseDelay {
            let verb = desired == nil ? "released" : "stepped up"
            SGLogger.shared.log(logTag, "throttle \(verb): level=\(level) held \(Int(now - coolerSince))s; \(limitsText(current)) -> \(limitsText(desired))")
            self.throttleTier = desired
            self.coolerSince = nil
        }
    }

    private func evaluate(reason: String?) {
        guard self.activeCount > 0 else {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        let level = SGThermalLevel(ProcessInfo.processInfo.thermalState)
        let userLimits = self.userLimits()

        self.updateThrottle(level: level, now: now, userLimits: userLimits)

        var limits = userLimits
        var throttle: SGThrottleState?
        if let tier = self.throttleTier {
            limits = userLimits.combined(with: tier.limits)
            throttle = SGThrottleState(tier: tier, limits: limits)
        }

        if self.appliedLimits != limits {
            if let previous = self.appliedLimits {
                SGLogger.shared.log(logTag, "limits \(previous) -> \(limits)")
            }
            self.appliedLimits = limits
            self.applyLimits?(limits)
        }

        let device = UIDevice.current
        let batteryLevel: Float? = device.batteryLevel >= 0.0 ? device.batteryLevel : nil
        let isCharging = device.batteryState == .charging || device.batteryState == .full

        let reading = SGThermalReading(
            level: level,
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            celsius: self.probe.read(),
            throttle: throttle,
            limits: limits
        )

        let previous = self.lastReading
        self.lastReading = reading
        self.readingPromise.set(reading)

        // A status line on every notable change, and every 30s regardless, so
        // a long call can be reconstructed from the log afterwards.
        let changed = previous == nil || previous?.level != reading.level || previous?.isCharging != reading.isCharging || previous?.throttle != reading.throttle
        if changed || now - self.lastLogTime >= SGCallThermalMonitor.logInterval {
            self.lastLogTime = now
            let why = reason.flatMap { " (\($0))" } ?? ""
            SGLogger.shared.log(logTag, "\(self.elapsedText()) \(self.describe(reading))\(why)")
        }
    }
}
