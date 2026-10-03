// Streams the drone phone's camera to the laptop ground station as JPEG frames
// over UDP (port 4211), split into <=1200-byte chunks.
//
// Cost control: only every 3rd camera frame (10 fps), 640x480, quality 0.45,
// encoded on a background queue. If the previous frame is still encoding the
// new one is skipped, so video can never back up into the vision pipeline.
// Enabled/disabled from the laptop page (the ESP32 relays the switch in telemetry).

import Foundation
import Network
import CoreImage
import ImageIO
import CoreVideo

final class VideoSender {
    private let queue = DispatchQueue(label: "droneboyfriendtracker.video", qos: .utility)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let lock = NSLock()
    private var busy = false
    private var active = false
    private var frameCounter = 0
    private var frameId: UInt16 = 0
    private var connection: NWConnection?
    private var connectedHost: String?

    private static let chunkSize = 1200
    private static let everyNthFrame = 3

    /// Call from the camera queue for every frame.
    func submit(_ pixelBuffer: CVPixelBuffer, box: CGRect?, tracking: Bool, enabled: Bool, laptopIP: String?) {
        guard enabled, let ip = laptopIP else {
            lock.lock()
            let wasActive = active
            active = false
            lock.unlock()
            if wasActive { queue.async { self.teardown() } }
            return
        }
        frameCounter += 1
        guard frameCounter % VideoSender.everyNthFrame == 0 else { return }
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        active = true
        lock.unlock()

        queue.async {
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            self.ensureConnection(ip)
            let image = CIImage(cvPixelBuffer: pixelBuffer)
            let options: [CIImageRepresentationOption: Any] = [
                CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.45
            ]
            guard let jpeg = self.ciContext.jpegRepresentation(of: image, colorSpace: self.colorSpace, options: options) else { return }
            self.sendFrame(jpeg, box: box, tracking: tracking)
        }
    }

    private func ensureConnection(_ ip: String) {
        if connectedHost == ip, connection != nil { return }
        teardown()
        let params = NWParameters.udp
        params.requiredInterfaceType = .wifi
        params.serviceClass = .interactiveVideo
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: Proto.videoPort)!, using: params)
        conn.start(queue: queue)
        connection = conn
        connectedHost = ip
    }

    private func teardown() {
        connection?.cancel()
        connection = nil
        connectedHost = nil
    }

    private func sendFrame(_ jpeg: Data, box: CGRect?, tracking: Bool) {
        guard let conn = connection else { return }
        frameId &+= 1
        let bytes = [UInt8](jpeg)
        let count = (bytes.count + VideoSender.chunkSize - 1) / VideoSender.chunkSize
        guard count > 0, count < 256 else { return }
        let b = box ?? .zero
        for i in 0..<count {
            var w = ByteWriter(capacity: 16 + VideoSender.chunkSize)
            w.u16(Proto.videoMagic)
            w.u16(frameId)
            w.u8(UInt8(i))
            w.u8(UInt8(count))
            w.u16(clampU16(Double(b.minX) * 10000))
            w.u16(clampU16(Double(b.minY) * 10000))
            w.u16(clampU16(Double(b.width) * 10000))
            w.u16(clampU16(Double(b.height) * 10000))
            w.u8(tracking ? 1 : 0)
            w.u8(0)
            let start = i * VideoSender.chunkSize
            let end = min(start + VideoSender.chunkSize, bytes.count)
            conn.send(content: Data(w.bytes + bytes[start..<end]), completion: .idempotent)
        }
    }
}
