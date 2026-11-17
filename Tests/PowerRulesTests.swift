import Foundation

extension AgentDetectionTests {
    static func powerRuleTests(_ check: Checker) {
        func reading(_ percent: Int?, onBattery: Bool = true, _ thermal: ProcessInfo.ThermalState = .nominal) -> PowerReading {
            PowerReading(batteryPercent: percent, onBattery: onBattery, thermal: thermal)
        }
        let low = PowerStop.lowBattery(percent: 9)

        check.equal(PowerRules.stop(after: nil, reading: reading(50)), nil, "healthy battery, cool Mac")
        check.equal(PowerRules.stop(after: nil, reading: reading(10)), nil, "the floor itself doesn't stop")
        check.equal(PowerRules.stop(after: nil, reading: reading(9)), low, "below the floor on battery stops")
        check.equal(PowerRules.stop(after: nil, reading: reading(5, onBattery: false)), nil, "charger power never stops for battery")
        check.equal(PowerRules.stop(after: nil, reading: reading(nil)), nil, "a Mac without a battery")
        check.equal(PowerRules.stop(after: low, reading: reading(12)), .lowBattery(percent: 12), "holds until the margin above the floor")
        check.equal(PowerRules.stop(after: low, reading: reading(15)), nil, "clears at the floor plus the margin")
        check.equal(PowerRules.stop(after: low, reading: reading(9, onBattery: false)), nil, "clears on charger power")

        check.equal(PowerRules.stop(after: nil, reading: reading(80, .fair)), nil, "fair heat alone doesn't stop")
        check.equal(PowerRules.stop(after: nil, reading: reading(80, .serious)), .heat, "serious heat stops")
        check.equal(PowerRules.stop(after: nil, reading: reading(80, onBattery: false, .critical)), .heat, "critical heat stops, even on charger power")
        check.equal(PowerRules.stop(after: .heat, reading: reading(80, .fair)), .heat, "heat holds through fair")
        check.equal(PowerRules.stop(after: .heat, reading: reading(80, .nominal)), nil, "heat clears at nominal")
        check.equal(PowerRules.stop(after: low, reading: reading(9, .serious)), .heat, "heat wins over a low battery")
        check.equal(PowerRules.stop(after: .heat, reading: reading(9, .nominal)), low, "a low battery shows once the Mac cools")
    }
}
