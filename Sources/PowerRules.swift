import Foundation
import IOKit.ps

/// Why the lid-closed mode is paused. A Mac kept awake with its lid shut can drain its battery
/// or overheat (in a bag, say), so while a stop holds, the lid setting goes back to macOS and a
/// closed Mac sleeps. The keep-awake modes themselves carry on.
enum PowerStop: Equatable {
    case lowBattery(percent: Int)
    case heat

    var message: String {
        switch self {
        case .lowBattery(let percent):
            "Paused: battery at \(percent)%. A closed Mac sleeps until you charge it."
        case .heat:
            "Paused: the Mac is hot. A closed Mac sleeps until it cools down."
        }
    }
}

struct PowerReading: Equatable {
    /// `nil` on a Mac without a battery.
    var batteryPercent: Int?
    var onBattery: Bool
    var thermal: ProcessInfo.ThermalState

    static func current() -> PowerReading {
        var reading = PowerReading(batteryPercent: nil, onBattery: false, thermal: ProcessInfo.processInfo.thermalState)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return reading }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                reading.batteryPercent = current * 100 / max
            }
            reading.onBattery = description[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
        }
        return reading
    }
}

enum PowerRules {
    /// On battery below this percentage, a battery stop starts.
    static let batteryFloor = 10
    /// It clears on charger power, or this many points above the floor, so it doesn't flap.
    static let batteryMargin = 5

    /// Heat stops start at macOS's `serious` thermal state and hold through `fair`, until
    /// `nominal`. Heat wins over a low battery: cooling down takes longer than plugging in.
    static func stop(after previous: PowerStop?, reading: PowerReading) -> PowerStop? {
        switch reading.thermal {
        case .serious, .critical: return .heat
        case .fair where previous == .heat: return .heat
        default: break
        }
        guard reading.onBattery, let percent = reading.batteryPercent else { return nil }
        let wasLow = if case .lowBattery = previous { true } else { false }
        let limit = wasLow ? batteryFloor + batteryMargin : batteryFloor
        return percent < limit ? .lowBattery(percent: percent) : nil
    }
}
