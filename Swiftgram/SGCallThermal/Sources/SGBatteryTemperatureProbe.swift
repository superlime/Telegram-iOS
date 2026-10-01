import Foundation

// MARK: Swiftgram
/// Best-effort battery temperature in °C, read from the IORegistry.
///
/// iOS has no public API for a temperature in degrees; `ProcessInfo.thermalState`
/// is the only public signal. This reads the `Temperature` property of the
/// `AppleSmartBattery` service (hundredths of a degree) through IOKit, which is
/// private on iOS, so it is loaded with `dlopen`/`dlsym` rather than linked.
///
/// The app sandbox blocks this lookup on recent iOS versions, so expect `nil`.
/// The first failure disables the probe for the rest of the process: every
/// attempt costs a sandbox denial, and the answer will not change.
final class SGBatteryTemperatureProbe {
    private typealias IOServiceMatchingFunction = @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFMutableDictionary>?
    // The matching dictionary is consumed by the callee.
    private typealias IOServiceGetMatchingServiceFunction = @convention(c) (UInt32, Unmanaged<CFMutableDictionary>?) -> UInt32
    private typealias IORegistryEntryCreateCFPropertyFunction = @convention(c) (UInt32, CFString, CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias IOObjectReleaseFunction = @convention(c) (UInt32) -> Int32

    private var isDisabled = false
    private var serviceMatching: IOServiceMatchingFunction?
    private var getMatchingService: IOServiceGetMatchingServiceFunction?
    private var createProperty: IORegistryEntryCreateCFPropertyFunction?
    private var objectRelease: IOObjectReleaseFunction?

    /// Called once with a human-readable outcome of the first read.
    var onFirstResult: ((String) -> Void)?
    private var didReportFirstResult = false

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            self.disable(reason: "IOKit could not be loaded")
            return
        }
        guard let serviceMatching = dlsym(handle, "IOServiceMatching"),
              let getMatchingService = dlsym(handle, "IOServiceGetMatchingService"),
              let createProperty = dlsym(handle, "IORegistryEntryCreateCFProperty"),
              let objectRelease = dlsym(handle, "IOObjectRelease") else {
            self.disable(reason: "IOKit symbols not found")
            return
        }
        self.serviceMatching = unsafeBitCast(serviceMatching, to: IOServiceMatchingFunction.self)
        self.getMatchingService = unsafeBitCast(getMatchingService, to: IOServiceGetMatchingServiceFunction.self)
        self.createProperty = unsafeBitCast(createProperty, to: IORegistryEntryCreateCFPropertyFunction.self)
        self.objectRelease = unsafeBitCast(objectRelease, to: IOObjectReleaseFunction.self)
    }

    private var pendingDisableReason: String?

    private func disable(reason: String) {
        self.isDisabled = true
        if self.onFirstResult == nil {
            // init-time failure; report on the first read, once the callback is set.
            self.pendingDisableReason = reason
        } else {
            self.report("unavailable (\(reason))")
        }
    }

    private func report(_ text: String) {
        if !self.didReportFirstResult {
            self.didReportFirstResult = true
            self.onFirstResult?(text)
        }
    }

    /// Current battery temperature, or nil when unavailable.
    func read() -> Double? {
        if let reason = self.pendingDisableReason {
            self.pendingDisableReason = nil
            self.report("unavailable (\(reason))")
        }
        if self.isDisabled {
            return nil
        }
        guard let serviceMatching = self.serviceMatching, let getMatchingService = self.getMatchingService, let createProperty = self.createProperty, let objectRelease = self.objectRelease else {
            self.disable(reason: "not initialised")
            return nil
        }

        let matching = "AppleSmartBattery".withCString { serviceMatching($0) }
        // kIOMainPortDefault is MACH_PORT_NULL.
        let service = getMatchingService(0, matching)
        if service == 0 {
            self.disable(reason: "AppleSmartBattery service not visible, probably blocked by the sandbox")
            return nil
        }
        defer {
            let _ = objectRelease(service)
        }

        guard let value = createProperty(service, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            self.disable(reason: "Temperature property not readable")
            return nil
        }
        guard let number = value as? NSNumber else {
            self.disable(reason: "Temperature property has unexpected type")
            return nil
        }
        let celsius = number.doubleValue / 100.0
        guard celsius > 0.0 && celsius < 80.0 else {
            self.disable(reason: "Temperature out of range: \(number)")
            return nil
        }
        self.report(String(format: "available, first reading %.1f°C", celsius))
        return celsius
    }
}
