// Проба доступности датчиков без root: AppleSMC, батарея, NVMe.
import IOKit
import IOKit.ps
import Darwin
import Foundation

struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0
}
struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}
struct SMCKeyInfoData {
    var dataSize: IOByteCount = 0, dataType: UInt32 = 0, attributes: UInt8 = 0
}
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)
struct SMCKeyData {
    var key: UInt32 = 0
    var vers: SMCVersion = SMCVersion()
    var pLimitData: SMCPLimitData = SMCPLimitData()
    var keyInfo: SMCKeyInfoData = SMCKeyInfoData()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

var conn: io_connect_t = 0

func smcCall(_ selector: UInt32, input: inout SMCKeyData, output: inout SMCKeyData) -> kern_return_t {
    let size = MemoryLayout<SMCKeyData>.stride
    var outSize = size
    return withUnsafeMutablePointer(to: &input) { inPtr in
        inPtr.withMemoryRebound(to: UInt8.self, capacity: size) { inBytes in
            withUnsafeMutablePointer(to: &output) { outPtr in
                outPtr.withMemoryRebound(to: UInt8.self, capacity: size) { outBytes in
                    IOConnectCallStructMethod(conn, selector, inBytes, size, outBytes, &outSize)
                }
            }
        }
    }
}

func strToKey(_ s: String) -> UInt32 {
    var v: UInt32 = 0
    for (i, ch) in s.utf8.prefix(4).enumerated() {
        v |= UInt32(ch) << UInt32((3 - i) * 8)
    }
    return v
}

func keyToStr(_ v: UInt32) -> String {
    String(format: "%c%c%c%c",
           UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF))
}

func typeStr(_ t: UInt32) -> String {
    keyToStr(t)
}

func readKeyInfo(_ name: String) -> (size: UInt32, type: UInt32)? {
    var input = SMCKeyData(), output = SMCKeyData()
    input.key = strToKey(name)
    input.data8 = 9 // READ_KEYINFO
    guard smcCall(9, input: &input, output: &output) == KERN_SUCCESS else { return nil }
    return (UInt32(output.keyInfo.dataSize), output.keyInfo.dataType)
}

func readKey(_ name: String) -> (bytes: [UInt8], size: UInt32, type: UInt32)? {
    guard let info = readKeyInfo(name) else { return nil }
    var input = SMCKeyData(), output = SMCKeyData()
    input.key = strToKey(name)
    input.keyInfo.dataSize = IOByteCount(info.size)
    input.data8 = 5 // READ_KEY
    guard smcCall(5, input: &input, output: &output) == KERN_SUCCESS else { return nil }
    return (withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }, info.size, info.type)
}

func value(_ name: String) -> Double? {
    guard let r = readKey(name) else { return nil }
    switch typeStr(r.type) {
    case "sp78", "fpe2":
        guard r.size >= 2 else { return nil }
        let v = Int16(bitPattern: UInt16(r.bytes[0]) << 8 | UInt16(r.bytes[1]))
        return Double(v) / 256.0
    case "flt ":
        guard r.size == 4 else { return nil }
        return Double(r.bytes.withUnsafeBytes { $0.load(as: Float.self) })
    default: return nil
    }
}

// 1. AppleSMC
let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
var openKr = kIOReturnError
if service != 0 {
    openKr = IOServiceOpen(service, mach_task_self_, 0, &conn)
    IOObjectRelease(service)
}
print("SMC open: kr=\(openKr) (0x\(String(openKr, radix: 16)))")
if openKr == KERN_SUCCESS {
    var input = SMCKeyData(), output = SMCKeyData()
    input.key = strToKey("#KEY")
    input.data8 = 9 // READ_KEYINFO
    let krInfo = smcCall(9, input: &input, output: &output)
    print("READ_KEYINFO(#KEY): kr=\(krInfo) (0x\(String(krInfo, radix: 16))) size=\(output.keyInfo.dataSize) type=\(typeStr(output.keyInfo.dataType)) result=\(output.result)")
    if let cnt = readKey("#KEY") {
        let count = cnt.bytes.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        print("SMC ключей всего: \(count)")
        var tCount = 0
        for i in 0..<count {
            var input = SMCKeyData(), output = SMCKeyData()
            input.data8 = 8 // READ_INDEX
            input.data32 = i
            guard smcCall(8, input: &input, output: &output) == KERN_SUCCESS else { continue }
            let name = keyToStr(output.key)
            guard name.hasPrefix("T") else { continue }
            tCount += 1
            if let v = value(name), (5.0...150.0).contains(v) {
                print(String(format: "  %@  = %.1f°C  (%@)", name, v, typeStr(readKeyInfo(name)?.type ?? 0)))
            }
        }
        print("Ключей на T: \(tCount)")
    }
} else {
    print("SMC недоступен без root — температуры через SMC потребуют прав root")
}

// 2. Батарея через IOPS
print("\n--- Батарея (IOPS) ---")
if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
   let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
    for s in sources {
        if let d = IOPSGetPowerSourceDescription(blob, s)?.takeUnretainedValue() as? [String: Any] {
            print("  Тип: \(d["Type"] ?? "?")  Заряд: \(d["Current Capacity"] ?? "?")%  Заряжается: \(d["Is Charging"] ?? "?")  Состояние: \(d["Power Source State"] ?? "?")  Время: \(d["Time Remaining"] ?? "?")")
        }
    }
} else {
    print("  Источников питания нет (Mac mini/Mac Studio?)")
}

// 3. Циклы батареи через реестр
let batt = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
if batt != 0 {
    defer { IOObjectRelease(batt) }
    var dict: Unmanaged<CFMutableDictionary>?
    if IORegistryEntryCreateCFProperties(batt, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
       let props = dict?.takeRetainedValue() as? [String: Any] {
        print("CycleCount: \(props["CycleCount"] ?? "н/д")  Temperature: \(props["Temperature"] ?? "н/д")  MaxCapacity: \(props["MaxCapacity"] ?? "н/д")  DesignCapacity: \(props["DesignCapacity"] ?? "н/д")")
    }
} else {
    print("AppleSmartBattery не найден")
}

// 4. NVMe температура
print("\n--- NVMe ---")
var iter: io_iterator_t = 0
if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeController"), &iter) == KERN_SUCCESS {
    defer { IOObjectRelease(iter) }
    var any = false
    while case let obj = IOIteratorNext(iter), obj != 0 {
        defer { IOObjectRelease(obj) }
        var dict: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(obj, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let props = dict?.takeRetainedValue() as? [String: Any] {
            let tempKeys = props.keys.filter { $0.localizedCaseInsensitiveContains("temp") }
            if !tempKeys.isEmpty {
                any = true
                for k in tempKeys { print("  \(k) = \(props[k] ?? "?")") }
            }
        }
    }
    if !any { print("  IONVMeController: свойств с температурой нет") }
}
