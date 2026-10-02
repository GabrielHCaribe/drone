// Binary UDP protocol. Must match firmware/DroneFC/protocol.h and docs/PROTOCOL.md.
// Every packet: [Header 8 bytes][payload][CRC16 2 bytes], little-endian.

import Foundation

enum Proto {
    static let magic: UInt16 = 0x4450
    static let version: UInt8 = 1
    static let droneHost = "192.168.4.1"
    static let dronePort: UInt16 = 4210
    static let videoPort: UInt16 = 4211
    static let videoMagic: UInt16 = 0x5650
    static let flagKill: UInt8 = 0x01
}

enum Source: UInt8 {
    case esp32 = 0, laptop = 1, remote = 2, drone = 3
}

enum PacketType: UInt8 {
    case heartbeat = 0x01, rc = 0x02, follow = 0x03, motorTest = 0x04
    case command = 0x10, paramGet = 0x11, paramSet = 0x12
    case telemetry = 0x80, cmdAck = 0x81, paramInfo = 0x82
}

enum DroneCommand: UInt8 {
    case arm = 1, disarm = 2, land = 3, startFollow = 4, cancelFollow = 5
    case calGyro = 6, calLevel = 7, paramSave = 8, paramReset = 9
    case escCalHigh = 10, escCalLow = 11, escCalExit = 12
    case videoOn = 13, videoOff = 14, kill = 15

    var label: String {
        switch self {
        case .arm: return "Arm"
        case .disarm: return "Disarm"
        case .land: return "Land"
        case .startFollow: return "Start follow"
        case .cancelFollow: return "Cancel follow"
        case .calGyro: return "Gyro calibration"
        case .calLevel: return "Level calibration"
        case .paramSave: return "Save"
        case .paramReset: return "Reset defaults"
        case .escCalHigh: return "ESC cal high"
        case .escCalLow: return "ESC cal low"
        case .escCalExit: return "ESC cal exit"
        case .videoOn: return "Video on"
        case .videoOff: return "Video off"
        case .kill: return "Kill"
        }
    }
}

enum FlightState: UInt8 {
    case boot = 0, disarmed, motorTest, escCal, followCountdown, manual, follow, failsafeHover, landing, killed, imuFault

    var label: String {
        switch self {
        case .boot: return "Calibrating"
        case .disarmed: return "Disarmed"
        case .motorTest: return "Motor test"
        case .escCal: return "ESC cal"
        case .followCountdown: return "Countdown"
        case .manual: return "Manual"
        case .follow: return "Follow"
        case .failsafeHover: return "Failsafe"
        case .landing: return "Landing"
        case .killed: return "KILLED"
        case .imuFault: return "IMU fault"
        }
    }
}

enum ResultCode: UInt8 {
    case ok = 0, wrongState, noLaptop, noPilot, throttleHigh, notLevel, imuNotReady, batteryLow, killLatched
    case noDronePhone, phoneNotReady, armed, badParam, notAllowed, unknown

    var label: String {
        switch self {
        case .ok: return "OK"
        case .wrongState: return "Not possible right now"
        case .noLaptop: return "Laptop kill switch not connected"
        case .noPilot: return "No stick packets"
        case .throttleHigh: return "Throttle not at the bottom"
        case .notLevel: return "Drone is not level"
        case .imuNotReady: return "IMU not ready"
        case .batteryLow: return "Battery low"
        case .killLatched: return "Kill is latched (press Disarm)"
        case .noDronePhone: return "Drone phone not connected"
        case .phoneNotReady: return "Drone phone sensors not ready"
        case .armed: return "Already armed"
        case .badParam: return "Bad parameter"
        case .notAllowed: return "Not allowed from this device"
        case .unknown: return "Unknown error"
        }
    }
}

enum LandReason: UInt8 {
    case noEvent = 0, command, laptopLost, pilotLost, dronePhoneLost, battery, followTimeout, targetLost
    case crash, killed, autoDisarm, touchdown, disarmCommand, imuFault

    var label: String {
        switch self {
        case .noEvent: return "-"
        case .command: return "Land command"
        case .laptopLost: return "Laptop link lost"
        case .pilotLost: return "Remote link lost"
        case .dronePhoneLost: return "Drone phone link lost"
        case .battery: return "Low battery"
        case .followTimeout: return "Follow time limit"
        case .targetLost: return "Target lost"
        case .crash: return "Crash detected"
        case .killed: return "Killed"
        case .autoDisarm: return "Auto-disarm"
        case .touchdown: return "Landed"
        case .disarmCommand: return "Disarmed"
        case .imuFault: return "IMU fault"
        }
    }
}

enum FollowPhase: UInt8 {
    case idle = 0, takeoff, acquire, track, lostHover, search, landing

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .takeoff: return "Taking off"
        case .acquire: return "Looking for you"
        case .track: return "Following"
        case .lostHover: return "Lost you - hovering"
        case .search: return "Searching"
        case .landing: return "Landing"
        }
    }
}

struct FollowFlags {
    static let ready: UInt8 = 0x01
    static let tracking: UInt8 = 0x02
    static let heightValid: UInt8 = 0x04
    static let active: UInt8 = 0x08
}

// MARK: - CRC + byte helpers

func crc16CCITT(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for b in bytes {
        crc ^= UInt16(b) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

struct ByteWriter {
    private(set) var bytes: [UInt8] = []
    init(capacity: Int = 32) { bytes.reserveCapacity(capacity) }
    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16(_ v: UInt16) { bytes.append(UInt8(v & 0xFF)); bytes.append(UInt8(v >> 8)) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func f32(_ v: Float) {
        let b = v.bitPattern
        for i in 0..<4 { bytes.append(UInt8((b >> (8 * UInt32(i))) & 0xFF)) }
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset: Int = 0
    init(_ bytes: [UInt8], offset: Int = 0) { self.bytes = bytes; self.offset = offset }
    var remaining: Int { bytes.count - offset }
    mutating func u8() -> UInt8 { let v = bytes[offset]; offset += 1; return v }
    mutating func u16() -> UInt16 { let v = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8); offset += 2; return v }
    mutating func i16() -> Int16 { Int16(bitPattern: u16()) }
    mutating func u32() -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
        offset += 4
        return v
    }
    mutating func f32() -> Float { Float(bitPattern: u32()) }
}

/// Clamp a Double into Int16 range.
@inline(__always) func clampI16(_ x: Double) -> Int16 { Int16(max(-32768, min(32767, x.rounded()))) }
@inline(__always) func clampU16(_ x: Double) -> UInt16 { UInt16(max(0, min(65535, x.rounded()))) }

enum PacketCodec {
    static func build(type: PacketType, source: Source, kill: Bool, seq: UInt16, payload: [UInt8] = []) -> Data {
        var w = ByteWriter(capacity: 10 + payload.count)
        w.u16(Proto.magic)
        w.u8(Proto.version)
        w.u8(type.rawValue)
        w.u8(source.rawValue)
        w.u8(kill ? Proto.flagKill : 0)
        w.u16(seq)
        var bytes = w.bytes + payload
        let crc = crc16CCITT(bytes)
        bytes.append(UInt8(crc & 0xFF))
        bytes.append(UInt8(crc >> 8))
        return Data(bytes)
    }

    /// Returns (type, payload) for a valid packet, nil otherwise.
    static func parse(_ data: Data) -> (PacketType, [UInt8])? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10 else { return nil }
        let crcRx = UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
        guard crcRx == crc16CCITT(Array(bytes[0..<(bytes.count - 2)])) else { return nil }
        var r = ByteReader(bytes)
        guard r.u16() == Proto.magic, r.u8() == Proto.version, let type = PacketType(rawValue: r.u8()) else { return nil }
        return (type, Array(bytes[8..<(bytes.count - 2)]))
    }
}

// MARK: - Payloads

struct RcPayload {
    var roll: Int16, pitch: Int16, yaw: Int16, throttle: UInt16
    var bytes: [UInt8] {
        var w = ByteWriter(capacity: 8)
        w.i16(roll); w.i16(pitch); w.i16(yaw); w.u16(throttle)
        return w.bytes
    }
}

struct FollowSetpoint {
    var rollDeg: Double = 0
    var pitchDeg: Double = 0          // + = nose up
    var yawRateDps: Double = 0        // + = nose right, 0 = hold heading
    var throttle: Double = 0          // 0..1
    var heightM: Double = 0
    var vzMps: Double = 0
    var phase: FollowPhase = .idle
    var flags: UInt8 = 0

    var bytes: [UInt8] {
        var w = ByteWriter(capacity: 14)
        w.i16(clampI16(rollDeg * 100))
        w.i16(clampI16(pitchDeg * 100))
        w.i16(clampI16(yawRateDps * 10))
        w.u16(clampU16(throttle * 1000))
        w.i16(clampI16(heightM * 100))
        w.i16(clampI16(vzMps * 100))
        w.u8(phase.rawValue)
        w.u8(flags)
        return w.bytes
    }
}

struct Telemetry {
    var state: FlightState
    var sflags: UInt8
    var armBlockManual: ResultCode
    var armBlockFollow: ResultCode
    var lastEvent: LandReason
    var roll: Double, pitch: Double, yaw: Double
    var vbat: Double
    var throttle: Double          // 0..1
    var hoverThrottle: Double     // 0..1
    var motors: [Double]          // 0..1
    var loopHz: Int, loopMaxUs: Int, loopJitterUs: Int
    var linkRate: [Int], linkLoss: [Int], linkAgeMs: [Int]
    var followLeft: Double, countdown: Double
    var heightM: Double
    var laptopIP: String?
    var uptime: Double

    var armed: Bool { sflags & 0x01 != 0 }
    var killLatched: Bool { sflags & 0x02 != 0 }
    var imuOK: Bool { sflags & 0x04 != 0 }
    var batteryWarn: Bool { sflags & 0x10 != 0 }
    var batteryPresent: Bool { sflags & 0x20 != 0 }
    var videoOn: Bool { sflags & 0x40 != 0 }
    var paramsDirty: Bool { sflags & 0x80 != 0 }
    var laptopConnected: Bool { linkAgeMs[0] < 500 }

    static let size = 56

    init?(_ p: [UInt8]) {
        guard p.count == Telemetry.size else { return nil }
        var r = ByteReader(p)
        state = FlightState(rawValue: r.u8()) ?? .boot
        sflags = r.u8()
        let ab = r.u8()
        armBlockManual = ResultCode(rawValue: ab & 0x0F) ?? .unknown
        armBlockFollow = ResultCode(rawValue: ab >> 4) ?? .unknown
        lastEvent = LandReason(rawValue: r.u8()) ?? .noEvent
        roll = Double(r.i16()) / 100
        pitch = Double(r.i16()) / 100
        yaw = Double(r.i16()) / 100
        vbat = Double(r.u16()) / 1000
        throttle = Double(r.u16()) / 1000
        hoverThrottle = Double(r.u16()) / 1000
        motors = (0..<4).map { _ in Double(r.u16()) / 1000 }
        loopHz = Int(r.u16())
        loopMaxUs = Int(r.u16())
        loopJitterUs = Int(r.u16())
        linkRate = (0..<3).map { _ in Int(r.u8()) }
        linkLoss = (0..<3).map { _ in Int(r.u8()) }
        linkAgeMs = (0..<3).map { _ in Int(r.u16()) }
        followLeft = Double(r.u16()) / 10
        countdown = Double(r.u16()) / 10
        heightM = Double(r.i16()) / 100
        let ip = (0..<4).map { _ in r.u8() }
        laptopIP = ip[0] == 0 ? nil : ip.map(String.init).joined(separator: ".")
        uptime = Double(r.u32()) / 1000
    }
}

struct CommandAck {
    let command: DroneCommand?
    let result: ResultCode
    let time: Date

    init?(_ p: [UInt8]) {
        guard p.count == 4 else { return nil }
        command = DroneCommand(rawValue: p[0])
        result = ResultCode(rawValue: p[1]) ?? .unknown
        time = Date()
    }
}

struct ParamInfo: Identifiable, Equatable {
    let id: Int
    let count: Int
    var value: Float
    let min: Float
    let max: Float
    let name: String

    init?(_ p: [UInt8]) {
        guard p.count == 38 else { return nil }
        var r = ByteReader(p)
        id = Int(r.u8())
        count = Int(r.u8())
        value = r.f32()
        min = r.f32()
        max = r.f32()
        let nameBytes = p[14..<38].prefix { $0 != 0 }
        name = String(decoding: nameBytes, as: UTF8.self)
    }
}
