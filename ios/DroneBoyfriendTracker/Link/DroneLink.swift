// UDP link to the ESP32 (192.168.4.1:4210). One instance per app.
//
// - A 50 Hz timer on a dedicated high-priority queue sends this phone's periodic
//   packet: sticks (Remote role) or follow setpoints (Drone role).
// - Commands are sent immediately and resent up to 3 times until acknowledged.
// - Every packet carries the kill flag while the local kill is latched.
// - Telemetry arrives at 20 Hz and is published to the UI on the main thread.

import Foundation
import Network
import Combine

final class DroneLink: ObservableObject {
    @Published private(set) var telemetry: Telemetry?
    @Published private(set) var connected = false
    @Published private(set) var lastAck: CommandAck?
    @Published private(set) var params: [ParamInfo] = []
    @Published private(set) var killLatched = false

    /// Called on the link queue at 50 Hz. Return the periodic packet to send, or nil.
    var periodicProvider: (() -> (PacketType, [UInt8])?)?
    /// Called on the link queue for every telemetry packet (before the UI update).
    var telemetryObserver: ((Telemetry) -> Void)?

    private(set) var source: Source = .remote
    private let queue = DispatchQueue(label: "droneboyfriendtracker.link", qos: .userInteractive)
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var seq: UInt16 = 0
    private var killFlag = false              // link-queue copy of killLatched
    private var motorTest: [UInt16]?          // link-queue only
    private var pending: [UInt16: (DroneCommand, UInt8, Date, Int)] = [:]
    private var lastTelemetryTime = Date.distantPast  // written on the link queue, read by the UI timer
    private var freshnessTimer: Timer?
    private let telemetryLock = NSLock()
    private var latestTelemetryUnsafe: Telemetry?

    /// Latest telemetry, safe to read from any thread.
    var latestTelemetry: Telemetry? {
        telemetryLock.lock(); defer { telemetryLock.unlock() }
        return latestTelemetryUnsafe
    }

    // MARK: lifecycle

    func start(as source: Source) {
        queue.async { self.startOnQueue(source) }
        DispatchQueue.main.async {
            self.freshnessTimer?.invalidate()
            self.freshnessTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                guard let self else { return }
                let fresh = Date().timeIntervalSince(self.lastTelemetryTime) < 0.6
                if fresh != self.connected { self.connected = fresh }
            }
        }
    }

    private func startOnQueue(_ source: Source) {
        stopOnQueue()
        self.source = source
        let params = NWParameters.udp
        params.requiredInterfaceType = .wifi
        params.serviceClass = .interactiveVoice  // WMM voice queue: lowest-latency WiFi access category
        let conn = NWConnection(host: NWEndpoint.Host(Proto.droneHost),
                                port: NWEndpoint.Port(rawValue: Proto.dronePort)!,
                                using: params)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                // WiFi dropped: rebuild the connection after a moment.
                self?.queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.connection === conn else { return }
                    self.startOnQueue(self.source)
                }
            }
        }
        conn.start(queue: queue)
        receive(on: conn)

        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        connection?.cancel()
        connection = nil
        pending.removeAll()
    }

    // MARK: sending

    private func nextSeq() -> UInt16 {
        seq &+= 1
        return seq
    }

    private func sendRaw(_ type: PacketType, _ payload: [UInt8] = []) -> UInt16 {
        let s = nextSeq()
        let data = PacketCodec.build(type: type, source: source, kill: killFlag, seq: s, payload: payload)
        connection?.send(content: data, completion: .idempotent)
        return s
    }

    private func tick() {
        if let packet = periodicProvider?() {
            _ = sendRaw(packet.0, packet.1)
        } else {
            _ = sendRaw(.heartbeat)
        }
        if let mt = motorTest {
            var w = ByteWriter(capacity: 8)
            for m in mt { w.u16(m) }
            _ = sendRaw(.motorTest, w.bytes)
        }
        // resend unacknowledged commands (60 ms apart, 3 tries)
        let now = Date()
        for (s, entry) in pending where now.timeIntervalSince(entry.2) > 0.06 * Double(entry.3) {
            pending[s] = nil
            if entry.3 < 3 {
                let ns = sendRaw(.command, [entry.0.rawValue, entry.1])
                pending[ns] = (entry.0, entry.1, entry.2, entry.3 + 1)
            }
        }
    }

    func send(_ command: DroneCommand, arg: UInt8 = 0) {
        queue.async {
            let s = self.sendRaw(.command, [command.rawValue, arg])
            self.pending[s] = (command, arg, Date(), 1)
        }
    }

    /// Emergency stop. Latches locally: every packet from this phone carries the
    /// kill flag until `disarm()` is pressed.
    func kill() {
        queue.async {
            self.killFlag = true
            for _ in 0..<3 { _ = self.sendRaw(.command, [DroneCommand.kill.rawValue, 0]) }
        }
        killLatched = true
    }

    /// Disarm also clears a local kill latch.
    func disarm() {
        queue.async { self.killFlag = false }
        killLatched = false
        send(.disarm)
    }

    func setMotorTest(_ values: [UInt16]?) {
        queue.async { self.motorTest = values }
    }

    func requestParams() {
        queue.async { _ = self.sendRaw(.paramGet) }
    }

    func setParam(id: Int, value: Float) {
        queue.async {
            var w = ByteWriter(capacity: 5)
            w.u8(UInt8(id))
            w.f32(value)
            _ = self.sendRaw(.paramSet, w.bytes)
        }
    }

    // MARK: receiving

    private func receive(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let packet = PacketCodec.parse(data) {
                self.handle(packet.0, packet.1)
            }
            if error == nil, self.connection === conn {
                self.receive(on: conn)
            }
        }
    }

    private func handle(_ type: PacketType, _ payload: [UInt8]) {
        switch type {
        case .telemetry:
            guard let t = Telemetry(payload) else { return }
            lastTelemetryTime = Date()
            telemetryLock.lock(); latestTelemetryUnsafe = t; telemetryLock.unlock()
            telemetryObserver?(t)
            DispatchQueue.main.async {
                self.telemetry = t
                if !self.connected { self.connected = true }
            }
        case .cmdAck:
            guard let ack = CommandAck(payload) else { return }
            pending = pending.filter { $0.value.0 != ack.command }
            DispatchQueue.main.async { self.lastAck = ack }
        case .paramInfo:
            guard let p = ParamInfo(payload) else { return }
            DispatchQueue.main.async {
                if let i = self.params.firstIndex(where: { $0.id == p.id }) {
                    self.params[i] = p
                } else {
                    self.params.append(p)
                    self.params.sort { $0.id < $1.id }
                }
            }
        default:
            break
        }
    }
}
