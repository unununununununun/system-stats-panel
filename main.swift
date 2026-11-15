// Плавающая панель мониторинга: ЦП/память/диск + температуры (ЦП, GPU, SSD, АКБ) и батарея.
// Категории сгруппированы боксами (GroupBox), фон — Liquid Glass (.glassEffect, macOS 26).
// Сборка и установка: ./build.sh   |   Проверка рендера: StatsPanel --render-check
//
// SMC: внешний метод селектора 2, команда в data8 (8=READ_INDEX, 9=READ_KEYINFO, 5=READ_KEY).

import AppKit
import SwiftUI
import Combine
import IOKit
import IOKit.ps
import Darwin

// MARK: - SMC клиент

struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0
}
struct SMCLimits {
    var version: UInt16 = 0, length: UInt16 = 0, cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0
}
struct SMCKeyInfo {
    var dataSize: UInt32 = 0, dataType: UInt32 = 0, attributes: UInt8 = 0
}
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)
struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var limits = SMCLimits()
    var info = SMCKeyInfo()
    var padding: UInt16 = 0 // выравнивает структуру до 80 байт (как в C)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMCClient {
    private var conn: io_connect_t = 0
    private var cpuKeys: [UInt32] = []
    private var gpuKeys: [UInt32] = []
    private var storageKeys: [UInt32] = []
    private var batteryKey: UInt32 = 0
    private var sizes: [UInt32: UInt32] = [:]
    private var discovered = false
    private var loggedFirst = false
    private var failedSamples = 0
    private var readLogCount = 0

    /// Отладка в /tmp/stats_panel_debug.log.
    func dbg(_ s: String) {
        let line = "\(Date().timeIntervalSince1970) \(s)\n"
        let path = "/tmp/stats_panel_debug.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            defer { fh.closeFile() }
            fh.seekToEndOfFile()
            if let d = line.data(using: .utf8) { fh.write(d) }
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Открыть соединение и найти ключи датчиков. Вызывается лениво, один раз.
    private func discover() {
        discovered = true
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { dbg("discover: service=0"); return }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        dbg("discover: open kr=\(kr) conn=\(conn) stride=\(MemoryLayout<SMCKeyData>.stride)")
        guard kr == KERN_SUCCESS, conn != 0 else { conn = 0; return }

        let storageNames: Set<UInt32> = [keyVal("TSDD"), keyVal("TVN0"), keyVal("TVN1")]
        for index: UInt32 in 0..<3000 {
            var input = SMCKeyData(), output = SMCKeyData()
            input.data8 = 8          // READ_INDEX
            input.data32 = index
            guard Self.call(conn, &input, &output), output.result == 0 else { continue }
            let name = fourCC(output.key)
            if name.hasPrefix("Tp") { cpuKeys.append(output.key) }
            else if name.hasPrefix("Tg") { gpuKeys.append(output.key) }
            else if storageNames.contains(output.key) { storageKeys.append(output.key) }
            else if name == "TB0T" { batteryKey = output.key }
            else { continue }
            var infoIn = SMCKeyData(), infoOut = SMCKeyData()
            infoIn.key = output.key
            infoIn.data8 = 9          // READ_KEYINFO
            guard Self.call(conn, &infoIn, &infoOut), infoOut.result == 0,
                  fourCC(infoOut.info.dataType) == "flt " else {
                if name == "TB0T" { batteryKey = 0 }
                else if storageNames.contains(output.key) { storageKeys.removeAll { $0 == output.key } }
                else if name.hasPrefix("Tp") { cpuKeys.removeAll { $0 == output.key } }
                else if name.hasPrefix("Tg") { gpuKeys.removeAll { $0 == output.key } }
                continue
            }
            sizes[output.key] = infoOut.info.dataSize
        }
        dbg("discovered: cpu=\(cpuKeys.count) gpu=\(gpuKeys.count) ssd=\(storageKeys.count) batt=\(batteryKey) sizes=\(sizes.count)")
    }

    func temperatures() -> (cpu: Double?, gpu: Double?, ssd: Double?, battery: Double?) {
        if !discovered { discover() }
        guard conn != 0 else { return (nil, nil, nil, nil) }
        let result = (maxTemp(cpuKeys), maxTemp(gpuKeys), maxTemp(storageKeys),
                      batteryKey != 0 ? maxTemp([batteryKey]) : nil)
        if !loggedFirst {
            loggedFirst = true
            dbg("first sample: cpu=\(String(describing: result.0)) gpu=\(String(describing: result.1)) ssd=\(String(describing: result.2)) batt=\(String(describing: result.3))")
        }
        // Самовосстановление: чтения могут быть отклонены сразу после запуска
        // (SMC занят умирающим прошлым экземпляром) — через 5 пустых сэмплов переподключаемся.
        let allNil = result.0 == nil && result.1 == nil && result.2 == nil
        if allNil {
            failedSamples += 1
            if failedSamples >= 5 {
                dbg("reconnecting after \(failedSamples) empty samples")
                failedSamples = 0
                discovered = false
                cpuKeys = []; gpuKeys = []; storageKeys = []; batteryKey = 0; sizes = [:]
                if conn != 0 { IOServiceClose(conn); conn = 0 }
            }
        } else {
            failedSamples = 0
        }
        return result
    }

    private func maxTemp(_ keys: [UInt32]) -> Double? {
        var best: Double?
        for key in keys {
            guard let value = readTemperature(key), value > 1, value < 125 else { continue }
            best = max(best ?? value, value)
        }
        return best
    }

    private func readTemperature(_ key: UInt32) -> Double? {
        guard let size = sizes[key] else { return nil }
        var input = SMCKeyData(), output = SMCKeyData()
        input.key = key
        input.info.dataSize = size
        input.data8 = 5          // READ_KEY
        let krOk = Self.call(conn, &input, &output)
        let raw = output.bytes
        let bytes: [UInt8] = [raw.0, raw.1, raw.2, raw.3]
        let value = bytes.withUnsafeBytes { Double($0.load(as: Float.self)) }
        if readLogCount < 12 { // детальные данные о первых чтениях — для диагностики «пустых» запусков
            let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            dbg("read \(fourCC(key)): krOk=\(krOk) result=\(output.result) status=\(output.status) size=\(size) bytes=[\(hex)] float=\(value)")
            readLogCount += 1
        }
        guard krOk, output.result == 0 else { return nil }
        return value.isFinite ? value : nil
    }

    /// Единая точка входа: внешний метод 2, команда — в data8.
    private static func call(_ conn: io_connect_t, _ input: inout SMCKeyData, _ output: inout SMCKeyData) -> Bool {
        let size = MemoryLayout<SMCKeyData>.stride
        var outputSize = size
        let kr = withUnsafeMutablePointer(to: &input) { inPtr in
            inPtr.withMemoryRebound(to: UInt8.self, capacity: size) { inBytes in
                withUnsafeMutablePointer(to: &output) { outPtr in
                    outPtr.withMemoryRebound(to: UInt8.self, capacity: size) { outBytes in
                        IOConnectCallStructMethod(conn, 2, inBytes, size, outBytes, &outputSize)
                    }
                }
            }
        }
        return kr == KERN_SUCCESS
    }

    private func keyVal(_ s: String) -> UInt32 {
        var v: UInt32 = 0
        for (i, b) in s.utf8.prefix(4).enumerated() { v |= UInt32(b) << UInt32((3 - i) * 8) }
        return v
    }

    private func fourCC(_ v: UInt32) -> String {
        let b0 = UInt8((v >> 24) & 0xff), b1 = UInt8((v >> 16) & 0xff)
        let b2 = UInt8((v >> 8) & 0xff), b3 = UInt8(v & 0xff)
        return String(UnicodeScalar(b0)) + String(UnicodeScalar(b1))
             + String(UnicodeScalar(b2)) + String(UnicodeScalar(b3))
    }
}

// MARK: - Батарея

struct BatteryInfo {
    var percent: Double = 0
    var charging = false
    var onAC = false
    var minutesRemaining: Int = -1
    var cycleCount: Int?
    var tempC: Double?
}

final class BatteryMonitor {
    /// nil — батареи нет (Mac mini / Studio).
    func sample() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == "InternalBattery" else { continue } // kIOPSTypeInternalBattery
            var info = BatteryInfo()
            info.percent = Double((d[kIOPSCurrentCapacityKey] as? Int) ?? 0)
            info.charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            info.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            info.minutesRemaining = (d["Time Remaining"] as? Int) ?? -1 // kIOPSTimeRemainingKey

            let batt = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if batt != 0 {
                defer { IOObjectRelease(batt) }
                if let v = IORegistryEntryCreateCFProperty(batt, "CycleCount" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
                    info.cycleCount = v as? Int
                }
                if let v = IORegistryEntryCreateCFProperty(batt, "Temperature" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                    info.tempC = Double(v) / 10.0 - 273.15
                }
            }
            return info
        }
        return nil
    }
}

// MARK: - Загрузка GPU (IOAccelerator PerformanceStatistics)

private let kIOAcceleratorClassName = "IOAccelerator"

final class GPULoadMonitor {
    func sample() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching(kIOAcceleratorClassName), &iter
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var peak: Double?
        while true {
            let obj = IOIteratorNext(iter)
            guard obj != 0 else { break }
            defer { IOObjectRelease(obj) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(obj, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            let pct = stats["Device Utilization %"] as? Int
                ?? stats["GPU Activity(%)"] as? Int
                ?? stats["Renderer Utilization %"] as? Int
            guard let pct else { continue }
            let fraction = min(max(Double(pct) / 100.0, 0), 1)
            peak = max(peak ?? 0, fraction)
        }
        return peak
    }
}

// MARK: - Сводный монитор

struct Stats {
    var cpu: Double = 0                    // 0...1
    var cpuTemp: Double?
    var gpu: Double?
    var gpuTemp: Double?
    var ssdTemp: Double?
    var memUsed: Double = 0
    var memTotal: Double = 0
    var diskUsed: Double = 0
    var diskTotal: Double = 0
    var battery: BatteryInfo?

    var memPercent: Double { memTotal > 0 ? memUsed / memTotal : 0 }
    var diskPercent: Double { diskTotal > 0 ? diskUsed / diskTotal : 0 }
}

final class SystemMonitor {
    static let shared = SystemMonitor()
    private let smc = SMCClient()
    private let batteryMonitor = BatteryMonitor()
    private let gpuMonitor = GPULoadMonitor()
    private var prevTicks: [Int32] = []

    func sample() -> Stats {
        var s = Stats()
        s.cpu = sampleCPU()
        s.gpu = gpuMonitor.sample()
        let temps = smc.temperatures()
        s.cpuTemp = temps.cpu
        s.gpuTemp = temps.gpu
        s.ssdTemp = temps.ssd
        let mem = sampleMemory()
        s.memUsed = mem.used
        s.memTotal = mem.total
        let disk = sampleDisk()
        s.diskUsed = disk.used
        s.diskTotal = disk.total
        s.battery = batteryMonitor.sample()
        if var b = s.battery, b.tempC == nil, let smcTemp = temps.battery {
            b.tempC = smcTemp // запасной путь, если в реестре нет Temperature
            s.battery = b
        }
        return s
    }

    /// Загрузка ЦП по разности счётчиков времени всех ядер.
    private func sampleCPU() -> Double {
        var cpuCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let kr = host_processor_info(mach_host_self(), 2 /* PROCESSOR_INFO_BASIC */, &cpuCount, &cpuInfo, &infoCount)
        guard kr == KERN_SUCCESS, let info = cpuInfo else { return 0 }
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), size)
        }

        var ticks: [Int32] = []
        ticks.reserveCapacity(Int(cpuCount) * 4)
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            ticks.append(contentsOf: [
                info[base + Int(CPU_STATE_USER)],
                info[base + Int(CPU_STATE_SYSTEM)],
                info[base + Int(CPU_STATE_IDLE)],
                info[base + Int(CPU_STATE_NICE)],
            ])
        }

        guard prevTicks.count == ticks.count else {
            prevTicks = ticks
            return 0
        }
        var busy: UInt64 = 0
        var all: UInt64 = 0
        for i in 0..<ticks.count {
            let delta = Int64(ticks[i]) - Int64(prevTicks[i])
            guard delta > 0 else { continue }
            all &+= UInt64(delta)
            if i % 4 != 2 { busy &+= UInt64(delta) } // индекс 2 — idle
        }
        prevTicks = ticks
        guard all > 0 else { return 0 }
        return min(max(Double(busy) / Double(all), 0), 1)
    }

    /// Память: wired + compressor + active.
    private func sampleMemory() -> (used: Double, total: Double) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0) }
        var basic = host_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr2 = withUnsafeMutablePointer(to: &basic) { basicPtr in
            basicPtr.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { intPtr in
                host_info(hostPort, HOST_BASIC_INFO, intPtr, &basicCount)
            }
        }
        guard kr2 == KERN_SUCCESS else { return (0, 0) }
        let pageSize = Double(vm_kernel_page_size)
        let usedPages = UInt64(stats.wire_count) &+ UInt64(stats.compressor_page_count) &+ UInt64(stats.active_count)
        return (Double(usedPages) * pageSize, Double(basic.max_mem))
    }

    /// Корневой том: занято = всего − доступно.
    private func sampleDisk() -> (used: Double, total: Double) {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]) else { return (0, 0) }
        let total = Double(values.volumeTotalCapacity ?? 0)
        let free = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
        return (max(total - free, 0), total)
    }
}

// MARK: - Отладочный лог

func panelLog(_ s: String) {
    let line = "\(Date().timeIntervalSince1970) \(s)\n"
    let path = "/tmp/stats_panel_debug.log"
    if let fh = FileHandle(forWritingAtPath: path) {
        defer { fh.closeFile() }
        fh.seekToEndOfFile()
        if let d = line.data(using: .utf8) { fh.write(d) }
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - Форматирование

func formatBytes(_ bytes: Double, countStyle: ByteCountFormatter.CountStyle) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: countStyle)
}
func formatTemp(_ t: Double?, unavailable: String = "n/a") -> String {
    guard let t else { return unavailable }
    return String(format: "%.0f°", t)
}

/// UI strings: default English (`languageIndex == 0`), Russian when `1`.
struct PanelL10n {
    let windowTitle: String
    let settings: String
    let compactView: String
    let close: String
    let backToMonitor: String
    let expandPanel: String
    let compactEmpty: String
    let catCPU: String
    let catMemory: String
    let catDisk: String
    let catBattery: String
    let load: String
    let temperature: String
    let used: String
    let charge: String
    let themeSystem: String
    let themeLight: String
    let themeDark: String
    let compactCPU: String
    let compactRAM: String
    let compactDisk: String
    let tempNA: String
    let helpCPUTemp: String
    let helpGPUTemp: String
    let helpGPULoad: String
    let helpSSDTemp: String
    let helpBattTemp: String
    let batteryLabel: String
    let batteryCharging: String
    let batteryOnAC: String
    let batteryTimeFormat: String
    let batteryGeneric: String
    let cyclesFormat: String
    let capacityOfFormat: String

    static let en = PanelL10n(
        windowTitle: "System Monitor",
        settings: "Settings",
        compactView: "Compact view",
        close: "Close",
        backToMonitor: "Back to monitor",
        expandPanel: "Expand panel",
        compactEmpty: "Turn on metrics in Settings",
        catCPU: "CPU",
        catMemory: "Memory",
        catDisk: "Disk",
        catBattery: "Battery",
        load: "Load",
        temperature: "Temperature",
        used: "Used",
        charge: "Charge",
        themeSystem: "System",
        themeLight: "Light",
        themeDark: "Dark",
        compactCPU: "CPU",
        compactRAM: "RAM",
        compactDisk: "Disk",
        tempNA: "n/a",
        helpCPUTemp: "Peak CPU core temperature (SMC)",
        helpGPUTemp: "GPU temperature (SMC)",
        helpGPULoad: "Device utilization (IOAccelerator)",
        helpSSDTemp: "Storage temperature (SMC)",
        helpBattTemp: "Battery temperature (AppleSmartBattery)",
        batteryLabel: "Battery",
        batteryCharging: "charging",
        batteryOnAC: "on power",
        batteryTimeFormat: "%d:%02d left",
        batteryGeneric: "battery",
        cyclesFormat: "Cycles: %d",
        capacityOfFormat: "%@ of %@"
    )

    static let ru = PanelL10n(
        windowTitle: "Мониторинг системы",
        settings: "Настройки",
        compactView: "Компактный вид",
        close: "Закрыть",
        backToMonitor: "К мониторингу",
        expandPanel: "Развернуть панель",
        compactEmpty: "Включите метрики в настройках",
        catCPU: "ЦП",
        catMemory: "Память",
        catDisk: "Диск",
        catBattery: "Батарея",
        load: "Загрузка",
        temperature: "Температура",
        used: "Занято",
        charge: "Заряд",
        themeSystem: "Системная",
        themeLight: "Светлая",
        themeDark: "Тёмная",
        compactCPU: "ЦП",
        compactRAM: "ОЗУ",
        compactDisk: "Диск",
        tempNA: "н/д",
        helpCPUTemp: "Максимальная температура ядер CPU (SMC)",
        helpGPUTemp: "Температура GPU (SMC)",
        helpGPULoad: "Загрузка GPU (IOAccelerator)",
        helpSSDTemp: "Температура накопителя (SMC)",
        helpBattTemp: "Температура аккумулятора (реестр AppleSmartBattery)",
        batteryLabel: "Батарея",
        batteryCharging: "зарядка",
        batteryOnAC: "от сети",
        batteryTimeFormat: "осталось %d:%02d",
        batteryGeneric: "батарея",
        cyclesFormat: "Циклов: %d",
        capacityOfFormat: "%@ из %@"
    )

    static func forLanguageIndex(_ index: Int) -> PanelL10n { index == 1 ? .ru : .en }
}
func formatPercent(_ fraction: Double) -> String {
    String(format: "%.0f%%", min(max(fraction, 0), 1) * 100)
}

// MARK: - Настройки (UserDefaults)

extension UserDefaults {
    static func registerPanelDefaults() {
        UserDefaults.standard.register(defaults: [
            "panel.cpu": true, "panel.cpuTemp": true, "panel.gpu": true, "panel.gpuTemp": true,
            "panel.memory": true, "panel.disk": true, "panel.ssdTemp": true,
            "panel.battery": true, "panel.battTemp": true, "panel.compact": false,
            "panel.theme": 0, "panel.lang": 0,
        ])
    }
}

// MARK: - Строка метрики

struct MetricRow: View {
    let title: String
    let value: String
    let fraction: Double?
    let gradient: LinearGradient
    var help: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
            }
            if let fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule()
                            .fill(gradient)
                            .frame(width: max(3, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                            .animation(.easeOut(duration: 0.45), value: fraction)
                    }
                }
                .frame(height: 5)
            }
        }
        .help(help)
    }
}

// MARK: - Полный вид: категории-боксы

struct CategoryBox<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.07)))
    }
}

struct FullView: View {
    @ObservedObject var model: PanelModel

    private var L: PanelL10n { model.l10n }
    // Палитра v1 + отдельные цвета температур
    static let cpuBar = LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
    static let cpuTempBar = LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
    static let gpuBar = LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing)
    static let memBar = LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing)
    static let diskBar = LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing)
    static let ssdBar = LinearGradient(colors: [.yellow, .orange], startPoint: .leading, endPoint: .trailing)
    static let batteryBar = LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing)
    static let batteryLowBar = LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
    static let battTempBar = LinearGradient(colors: [.teal, .blue], startPoint: .leading, endPoint: .trailing)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            CategoryBox(title: L.catCPU, icon: "cpu") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.showCPU {
                        MetricRow(title: L.load,
                                  value: formatPercent(model.stats.cpu),
                                  fraction: model.stats.cpu,
                                  gradient: Self.cpuBar)
                    }
                    if model.showCPUTemp {
                        MetricRow(title: L.temperature,
                                  value: formatTemp(model.stats.cpuTemp, unavailable: L.tempNA),
                                  fraction: model.stats.cpuTemp.map { $0 / 100 },
                                  gradient: Self.cpuTempBar,
                                  help: L.helpCPUTemp)
                    }
                }
            }

            if model.showGPU || model.showGPUTemp {
                CategoryBox(title: "GPU", icon: "gamecontroller") {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.showGPU {
                            MetricRow(title: L.load,
                                      value: model.stats.gpu.map { formatPercent($0) } ?? L.tempNA,
                                      fraction: model.stats.gpu,
                                      gradient: Self.gpuBar,
                                      help: L.helpGPULoad)
                        }
                        if model.showGPUTemp {
                            MetricRow(title: L.temperature,
                                      value: formatTemp(model.stats.gpuTemp, unavailable: L.tempNA),
                                      fraction: model.stats.gpuTemp.map { $0 / 100 },
                                      gradient: Self.gpuBar,
                                      help: L.helpGPUTemp)
                        }
                    }
                }
            }

            if model.showMemory {
                CategoryBox(title: L.catMemory, icon: "memorychip") {
                    MetricRow(title: L.used,
                              value: formatPercent(model.stats.memPercent),
                              fraction: model.stats.memPercent,
                              gradient: Self.memBar,
                              help: String(format: L.capacityOfFormat,
                                           formatBytes(model.stats.memUsed, countStyle: .memory),
                                           formatBytes(model.stats.memTotal, countStyle: .memory)))
                }
            }

            CategoryBox(title: L.catDisk, icon: "internaldrive") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.showDisk {
                        MetricRow(title: L.used,
                                  value: formatPercent(model.stats.diskPercent),
                                  fraction: model.stats.diskPercent,
                                  gradient: Self.diskBar,
                                  help: String(format: L.capacityOfFormat,
                                               formatBytes(model.stats.diskUsed, countStyle: .file),
                                               formatBytes(model.stats.diskTotal, countStyle: .file)))
                    }
                    if model.showSSDTemp {
                        MetricRow(title: L.temperature,
                                  value: formatTemp(model.stats.ssdTemp, unavailable: L.tempNA),
                                  fraction: model.stats.ssdTemp.map { $0 / 100 },
                                  gradient: Self.ssdBar,
                                  help: L.helpSSDTemp)
                    }
                }
            }

            CategoryBox(title: L.catBattery, icon: "battery.100") {
                VStack(alignment: .leading, spacing: 6) {
                    if model.showBattery, let b = model.stats.battery {
                        batteryRow(b)
                    }
                    if model.showBattTemp, let b = model.stats.battery {
                        MetricRow(title: L.temperature,
                                  value: formatTemp(b.tempC, unavailable: L.tempNA),
                                  fraction: b.tempC.map { $0 / 100 },
                                  gradient: Self.battTempBar,
                                  help: L.helpBattTemp)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func batteryRow(_ b: BatteryInfo) -> some View {
        let status: String = {
            if b.charging { return L.batteryCharging }
            if b.onAC { return L.batteryOnAC }
            if b.minutesRemaining > 0 {
                return String(format: L.batteryTimeFormat,
                              b.minutesRemaining / 60, b.minutesRemaining % 60)
            }
            return L.batteryGeneric
        }()
        let help = b.cycleCount.map { String(format: L.cyclesFormat, $0) } ?? L.batteryLabel
        MetricRow(title: L.charge,
                  value: "\(Int(b.percent))% · \(status)",
                  fraction: b.percent / 100,
                  gradient: b.percent < 20 && !b.charging ? Self.batteryLowBar : Self.batteryBar,
                  help: help)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            Text(L.windowTitle)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            headerButton("gearshape", L.settings) {
                withAnimation(.easeInOut(duration: 0.22)) { model.showSettings = true }
            }
            headerButton("rectangle.compress.vertical", L.compactView) {
                withAnimation(.easeInOut(duration: 0.22)) { model.compact = true }
            }
            headerButton("xmark.circle", L.close) { NSApplication.shared.terminate(nil) }
        }
    }

    private func headerButton(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

// MARK: - Компактный вид

private struct CompactMetricItem: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let value: String
    let fraction: Double?
    let gradient: LinearGradient
    let valueColor: Color?
}

struct CompactView: View {
    @ObservedObject var model: PanelModel

    private var L: PanelL10n { model.l10n }

    private static let cpuBar = LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
    private static let gpuBar = LinearGradient(colors: [.purple, .indigo], startPoint: .leading, endPoint: .trailing)
    private static let tempBar = LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
    private static let memBar = LinearGradient(colors: [.green, .mint], startPoint: .leading, endPoint: .trailing)
    private static let diskBar = LinearGradient(colors: [.orange, .pink], startPoint: .leading, endPoint: .trailing)
    private static let batteryBar = LinearGradient(colors: [.green, .teal], startPoint: .leading, endPoint: .trailing)
    private static let batteryLowBar = LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)

    private let grid = [
        GridItem(.flexible(minimum: 96), spacing: 6),
        GridItem(.flexible(minimum: 96), spacing: 6),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            compactToolbar
            if metrics.isEmpty {
                Text(L.compactEmpty)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                LazyVGrid(columns: grid, alignment: .leading, spacing: 6) {
                    ForEach(metrics) { item in
                        compactChip(item)
                    }
                }
            }
        }
    }

    private var compactToolbar: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(L.windowTitle)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            toolbarButton("arrow.up.left.and.arrow.down.right", L.expandPanel) {
                withAnimation(.easeInOut(duration: 0.22)) { model.compact = false }
            }
            toolbarButton("gearshape", L.settings) {
                withAnimation(.easeInOut(duration: 0.22)) {
                    model.compact = false
                    model.showSettings = true
                }
            }
            toolbarButton("xmark.circle", L.close) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var metrics: [CompactMetricItem] {
        var list: [CompactMetricItem] = []
        let s = model.stats
        if model.showCPU {
            list.append(.init(id: "cpu", symbol: "cpu", title: L.compactCPU,
                              value: formatPercent(s.cpu), fraction: s.cpu, gradient: Self.cpuBar,
                              valueColor: nil))
        }
        if model.showGPU, let gpu = s.gpu {
            list.append(.init(id: "gpu", symbol: "gamecontroller", title: "GPU",
                              value: formatPercent(gpu), fraction: gpu, gradient: Self.gpuBar,
                              valueColor: nil))
        }
        if model.showCPUTemp || model.showGPUTemp || model.showSSDTemp || model.showBattTemp,
           let t = maxTemp {
            list.append(.init(id: "temp", symbol: "thermometer.medium", title: "T°",
                              value: formatTemp(t, unavailable: L.tempNA),
                              fraction: t / 100, gradient: Self.tempBar, valueColor: nil))
        }
        if model.showMemory {
            list.append(.init(id: "mem", symbol: "memorychip", title: L.compactRAM,
                              value: formatPercent(s.memPercent), fraction: s.memPercent,
                              gradient: Self.memBar, valueColor: nil))
        }
        if model.showDisk {
            list.append(.init(id: "disk", symbol: "internaldrive", title: L.compactDisk,
                              value: formatPercent(s.diskPercent), fraction: s.diskPercent,
                              gradient: Self.diskBar, valueColor: nil))
        }
        if model.showBattery, let b = s.battery {
            let low = b.percent < 20 && !b.charging
            list.append(.init(id: "batt", symbol: batterySymbol(b), title: L.charge,
                              value: "\(Int(b.percent))%", fraction: b.percent / 100,
                              gradient: low ? Self.batteryLowBar : Self.batteryBar,
                              valueColor: low ? .red : nil))
        }
        return list
    }

    private var maxTemp: Double? {
        [model.stats.cpuTemp, model.stats.gpuTemp, model.stats.ssdTemp, model.stats.battery?.tempC]
            .compactMap { $0 }.max()
    }

    private func compactChip(_ item: CompactMetricItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: item.symbol)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(item.value)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(item.valueColor ?? .primary)
                    .lineLimit(1)
            }
            if let fraction = item.fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(item.gradient)
                            .frame(width: max(2, geo.size.width * CGFloat(min(max(fraction, 0), 1))))
                            .animation(.easeOut(duration: 0.45), value: fraction)
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.06)))
    }

    private func toolbarButton(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func batterySymbol(_ b: BatteryInfo) -> String {
        if b.charging { return "battery.100.bolt" }
        switch b.percent {
        case 90...: return "battery.100"
        case 60..<90: return "battery.75"
        case 30..<60: return "battery.50"
        case 10..<30: return "battery.25"
        default: return "battery.0"
        }
    }
}

struct SettingsToolbar: View {
    @ObservedObject var model: PanelModel

    private var L: PanelL10n { model.l10n }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "gearshape")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            Text(L.settings)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("v1.5")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            headerButton("chevron.left", L.backToMonitor) {
                withAnimation(.easeInOut(duration: 0.22)) { model.showSettings = false }
            }
            headerButton("rectangle.compress.vertical", L.compactView) {
                withAnimation(.easeInOut(duration: 0.22)) { model.compact = true }
            }
            headerButton("xmark.circle", L.close) { NSApplication.shared.terminate(nil) }
        }
    }

    private func headerButton(_ symbol: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(tip)
    }
}

struct SettingsForm: View {
    @ObservedObject var model: PanelModel

    private var L: PanelL10n { model.l10n }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CategoryBox(title: L.catCPU, icon: "cpu") {
                VStack(alignment: .leading, spacing: 6) {
                    row(L.load, isOn: $model.showCPU)
                    row(L.temperature, isOn: $model.showCPUTemp)
                }
            }
            CategoryBox(title: "GPU", icon: "gamecontroller") {
                VStack(alignment: .leading, spacing: 6) {
                    row(L.load, isOn: $model.showGPU)
                    row(L.temperature, isOn: $model.showGPUTemp)
                }
            }
            CategoryBox(title: L.catMemory, icon: "memorychip") {
                row(L.used, isOn: $model.showMemory)
            }
            CategoryBox(title: L.catDisk, icon: "internaldrive") {
                VStack(alignment: .leading, spacing: 6) {
                    row(L.used, isOn: $model.showDisk)
                    row(L.temperature, isOn: $model.showSSDTemp)
                }
            }
            CategoryBox(title: L.catBattery, icon: "battery.100") {
                VStack(alignment: .leading, spacing: 6) {
                    row(L.charge, isOn: $model.showBattery)
                    row(L.temperature, isOn: $model.showBattTemp)
                }
            }
            viewAppearanceSection
        }
        .font(.system(size: 11))
        .controlSize(.small) // контролы в настройках компактные — как на главной странице
    }

    /// Тема + компактный вид без заголовка секции (подписи у контролов достаточно).
    private var viewAppearanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("", selection: $model.languageIndex) {
                Text("English").tag(0)
                Text("Русский").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("", selection: $model.themeIndex) {
                Text(L.themeSystem).tag(0)
                Text(L.themeLight).tag(1)
                Text(L.themeDark).tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            row(L.compactView, isOn: $model.compact)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.07)))
    }

    /// Стандартный macOS-switch: подпись слева, без пустого TextField у Toggle (давал I-beam).
    private func row(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.switch)
    }
}

struct SettingsView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsToolbar(model: model)
            SettingsForm(model: model)
        }
    }
}

// MARK: - Модель

@MainActor
final class PanelModel: ObservableObject {
    @Published var stats = SystemMonitor.shared.sample()
    @Published var showSettings = false
    @Published var showCPU = UserDefaults.standard.bool(forKey: "panel.cpu")
    @Published var showCPUTemp = UserDefaults.standard.bool(forKey: "panel.cpuTemp")
    @Published var showGPU = UserDefaults.standard.bool(forKey: "panel.gpu")
    @Published var showGPUTemp = UserDefaults.standard.bool(forKey: "panel.gpuTemp")
    @Published var showMemory = UserDefaults.standard.bool(forKey: "panel.memory")
    @Published var showDisk = UserDefaults.standard.bool(forKey: "panel.disk")
    @Published var showSSDTemp = UserDefaults.standard.bool(forKey: "panel.ssdTemp")
    @Published var showBattery = UserDefaults.standard.bool(forKey: "panel.battery")
    @Published var showBattTemp = UserDefaults.standard.bool(forKey: "panel.battTemp")
    @Published var compact = UserDefaults.standard.bool(forKey: "panel.compact")
    @Published var themeIndex = UserDefaults.standard.integer(forKey: "panel.theme")
    @Published var languageIndex = UserDefaults.standard.integer(forKey: "panel.lang")
    @Published var fullHeight: CGFloat = 440 // высота страницы мониторинга = размер контейнера
    @Published var compactHeight: CGFloat = 88

    var l10n: PanelL10n { PanelL10n.forLanguageIndex(languageIndex) }

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        timer.receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self else { return }
            self.stats = SystemMonitor.shared.sample()
        }
        .store(in: &cancellables)
        // Контейнер следует за главной страницей (и за компакт-режимом).
        $fullHeight.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, !self.showSettings else { return }
            AppDelegate.refitWindow()
        }
            .store(in: &cancellables)
        $compact.dropFirst().receive(on: RunLoop.main).sink { [weak self] compact in
            if compact { self?.showSettings = false }
            AppDelegate.refitWindow()
        }
            .store(in: &cancellables)
        $compactHeight.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            guard let self, self.compact else { return }
            AppDelegate.refitWindow()
        }
            .store(in: &cancellables)
    }

    fileprivate func persist(_ value: Bool, key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
    fileprivate func persist(_ value: Int, key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// ВРЕМЕННО: самопроверка «открыть-закрыть настройки» — воспроизводит действия
    /// пользователя без участия пользователя, геометрию пишут MeasureView/refit.
    func selfTest() {
        panelLog("selftest: open")
        withAnimation(.easeInOut(duration: 0.22)) { showSettings = true }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            panelLog("selftest: close")
            withAnimation(.easeInOut(duration: 0.22)) { self?.showSettings = false }
        }
    }
}

extension PanelModel {
    func bindDefaults() {
        func bind(_ publisher: Published<Bool>.Publisher, _ key: String) {
            publisher.dropFirst().sink { [weak self] v in self?.persist(v, key: key) }
                .store(in: &cancellables)
        }
        bind($showCPU, "panel.cpu")
        bind($showCPUTemp, "panel.cpuTemp")
        bind($showGPU, "panel.gpu")
        bind($showGPUTemp, "panel.gpuTemp")
        bind($showMemory, "panel.memory")
        bind($showDisk, "panel.disk")
        bind($showSSDTemp, "panel.ssdTemp")
        bind($showBattery, "panel.battery")
        bind($showBattTemp, "panel.battTemp")
        bind($compact, "panel.compact")
        $themeIndex.dropFirst().sink { [weak self] v in
            self?.persist(v, key: "panel.theme")
        }
        .store(in: &cancellables)
        $languageIndex.dropFirst().sink { [weak self] v in
            self?.persist(v, key: "panel.lang")
        }
        .store(in: &cancellables)
    }
}

// MARK: - Контент: слайдер настроек в том же размере + репорт размера окна

/// Измерение высоты вью через background GeometryReader: onChange(of: size) внутри
/// ридера доставляется надёжно, в отличие от onPreferenceChange (в этой композиции
/// — всегда смонтированный ScrollView-слой — preference-события не доходят).
fileprivate var canvasLogCount = 0

struct MeasureView: View {
    var logTag: String = ""
    let onChange: (CGFloat) -> Void
    var body: some View {
        GeometryReader { geo in
            let g = geo.frame(in: .global)
            Color.clear
                .onAppear {
                    if canvasLogCount < 30 {
                        panelLog("\(logTag): origin=\(g.origin) size=\(g.size)")
                        canvasLogCount += 1
                    }
                    onChange(geo.size.height)
                }
                .onChange(of: g) { newG in
                    if canvasLogCount < 30 {
                        panelLog("\(logTag): → origin=\(newG.origin) size=\(newG.size)")
                        canvasLogCount += 1
                    }
                }
                .onChange(of: geo.size.height) { onChange($0) }
        }
    }
}

struct ContentView: View {
    @StateObject private var model = PanelModel()
    @State private var canvasHeight: CGFloat = 0

    private var themeColorScheme: ColorScheme? {
        switch model.themeIndex {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            if model.compact {
                CompactView(model: model)
                    .frame(width: 236)
                    .background(MeasureView(logTag: "compact") { h in
                        if abs(h - model.compactHeight) > 0.5 { model.compactHeight = h }
                    })
                    .transition(.opacity)
            } else {
                // ОДИН контейнер, размер задаёт FullView. Обе страницы живут ПОСТОЯННО,
                // слайд — через offset: без transition-вставок (они застревали смещением,
                // когда ежесекундное обновление stats попадало в середину анимации).
                FullView(model: model)
                    .frame(width: 236)
                    .opacity(model.showSettings ? 0 : 1)
                    .background(MeasureView(logTag: "canvas") { h in
                        canvasHeight = h
                        guard !model.showSettings, abs(h - model.fullHeight) > 0.5 else { return }
                        model.fullHeight = h
                    })
                settingsPage
                    .offset(x: model.showSettings ? 0 : 236)
                    .opacity(model.showSettings ? 1 : 0)
                    .allowsHitTesting(model.showSettings)
            }
        }
        .clipped() // слайд уходит за край контейнера; углы не режутся
        .preferredColorScheme(themeColorScheme)
        .onChange(of: model.themeIndex) { AppDelegate.applyTheme($0) }
        .onChange(of: model.showSettings) { open in
            panelLog("showSettings → \(open)")
            if !open, canvasHeight > 0, abs(canvasHeight - model.fullHeight) > 0.5 {
                model.fullHeight = canvasHeight
                AppDelegate.refitWindow()
            }
        }
        .padding(10) // отступ контента от краёв стекла
        .textSelection(.disabled)
        .onAppear {
            panelLog("onAppear: compact=\(model.compact) showSettings=\(model.showSettings) cpu=\(model.showCPU) cpuTemp=\(model.showCPUTemp) gpu=\(model.showGPUTemp) mem=\(model.showMemory) disk=\(model.showDisk) ssd=\(model.showSSDTemp) batt=\(model.showBattery) battTemp=\(model.showBattTemp)")
            model.bindDefaults()
            AppDelegate.applyTheme(model.themeIndex)
        }
    }

    /// Настройки ровно в размер главной страницы: контейнер не увеличивается,
    /// при нехватке высоты содержимое прокручивается (без видимых полос).
    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsToolbar(model: model)
            ScrollView(.vertical) {
                SettingsForm(model: model)
                    .frame(width: 236)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 236, height: max(model.fullHeight, 60))
    }
}

// MARK: - Окно

/// NSPanel (.nonactivatingPanel) + SwiftUI Toggle/Picker иногда оставляют I-beam:
/// пустой label у Toggle — скрытый NSTextField, плюс залипание pointer stack без key window.
/// Контейнер принудительно регистрирует arrow и обновляет при входе мыши.
final class PanelArrowContainerView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner as AnyObject === self {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        window?.invalidateCursorRects(for: self)
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private static var activePanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingView(rootView: ContentView())
        var size = hosting.fittingSize
        if size.width < 120 { size.width = 264 }
        if size.height < 80 { size.height = 200 }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Матовое стекло: эффект-вью — ФОНОВЫЙ слой, SwiftUI-контент — соседний слой сверху
        // (если hosting потомок эффект-вью, контролы наследуют vibrancy и switch ON/OFF
        // выглядят одинаково). ВАЖНО: container сразу с реальным frame, а frame/autoresizing
        // сабвью — ПОСЛЕ contentView=container: иначе при первом авторесайзе (0×0 → окно)
        // flexible-сабвью удваиваются (512×897 вместо 256×437), канвас центрируется в
        // удвоенном вью и контент уезжает вправо-вверх («слева пусто», инцидент 15.11).
        let container = PanelArrowContainerView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.masksToBounds = true
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        container.addSubview(effect)
        container.addSubview(hosting)
        panel.contentView = container
        effect.frame = container.bounds
        hosting.frame = container.bounds
        effect.autoresizingMask = [.width, .height]
        hosting.autoresizingMask = [.width, .height]
        Self.activePanel = panel

        // ВРЕМЕННО: дамп слоёв через 2 с после запуска — кто где стоит на самом деле
        let effectRef = effect
        let hostingRef = hosting
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            panelLog("dump: window=\(panel.frame) container.bounds=\(container.bounds) effect=\(effectRef.frame) hosting=\(hostingRef.frame) fitting=\(hostingRef.fittingSize)")
        }

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 16 - panel.frame.width,
                                               y: frame.maxY - 16))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    /// Тема: стекло светлое/тёмное/системное.
    static func applyTheme(_ index: Int) {
        guard let panel = activePanel else { return }
        switch index {
        case 1: panel.appearance = NSAppearance(named: .aqua)
        case 2: panel.appearance = NSAppearance(named: .darkAqua)
        default: panel.appearance = nil // системная
        }
    }

    /// Окно следует за размером SwiftUI-контента (hosting.fittingSize), верхний край на месте.
    private static var refitLogCount = 0
    static func refitWindow() {
        guard let panel = activePanel,
              let hosting = panel.contentView?.subviews.last else { return }
        var size = hosting.fittingSize
        if size.width < 120 { size.width = 256 }
        if size.height < 24 { size.height = 88 }
        if refitLogCount < 10 {
            panelLog("refit #\(refitLogCount): fitting=\(size), текущий frame=\(panel.frame.size)")
            refitLogCount += 1
        }
        if abs(panel.frame.width - size.width) < 1, abs(panel.frame.height - size.height) < 1 { return }
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let newFrame = NSRect(x: topLeft.x, y: topLeft.y - size.height,
                              width: size.width, height: size.height)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
        if let container = panel.contentView {
            panel.invalidateCursorRects(for: container)
        }
    }
}

// MARK: - Проверка рендера (StatsPanel --render-check): PNG панели с реальными данными

@MainActor
func renderCheck() {
    let model = PanelModel()
    model.stats = SystemMonitor.shared.sample()
    func png(_ view: some View, _ path: String) -> CGFloat? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let image = renderer.nsImage,
           let rep = NSBitmapImageRep(data: image.tiffRepresentation!) {
            try? rep.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: path))
            fputs("render saved: \(path)\n", stderr)
            return CGFloat(rep.pixelsHigh) / 2
        } else {
            fputs("render FAILED: \(path)\n", stderr)
            return nil
        }
    }
    let light = Color(nsColor: .windowBackgroundColor)
    let dark = Color(nsColor: .underPageBackgroundColor)
    _ = png(FullView(model: model).frame(width: 236).padding(12).background(light), "/tmp/panel_render.png")
    let fullH = png(FullView(model: model).frame(width: 236).padding(12).background(dark)
        .environment(\.colorScheme, .dark), "/tmp/panel_render_dark.png")
    let natH = png(SettingsView(model: model).frame(width: 236).padding(12).background(dark)
        .environment(\.colorScheme, .dark), "/tmp/panel_render_settings_natural.png")
    // Настройки ровно как в живой панели: зажаты в высоту главной.
    // ImageRenderer не рисует содержимое ScrollView, поэтому для превью — frame+clipped
    // (в живой панели реальный ScrollView с прокруткой).
    if let h = fullH {
        _ = png(SettingsView(model: model)
            .frame(width: 236)
            .frame(height: h, alignment: .top)
            .clipped()
            .padding(12).background(dark)
            .environment(\.colorScheme, .dark), "/tmp/panel_render_settings.png")
    }
    if let h = fullH, let n = natH {
        fputs("высота: главная=\(h) настройки=\(n)\(n > h ? " → прокрутка \((n - h))pt" : " → влезает")\n", stderr)
    }
    exit(0)
}

// MARK: - Запуск

UserDefaults.registerPanelDefaults()

let buildDate = (try? FileManager.default.attributesOfItem(atPath: CommandLine.arguments[0])[.modificationDate]) as? Date
SMCClient().dbg("app launch, build: \(buildDate.map { ISO8601DateFormatter().string(from: $0) } ?? "?")")

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

if CommandLine.arguments.contains("--render-check") {
    MainActor.assumeIsolated { renderCheck() }
}

app.run()
