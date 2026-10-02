// Joins the drone's WiFi access point automatically (NEHotspotConfiguration).
// SSID and password come from Info.plist, which gets them from Secrets.xcconfig
// at build time (the CI build writes that file from GitHub secrets).

import Foundation
import NetworkExtension

enum WiFiJoiner {
    static var ssid: String {
        (Bundle.main.object(forInfoDictionaryKey: "DroneWiFiSSID") as? String) ?? "PinkDrone"
    }

    private static var password: String {
        (Bundle.main.object(forInfoDictionaryKey: "DroneWiFiPassword") as? String) ?? ""
    }

    /// Calls back on the main thread with nil on success, or an error message.
    static func join(completion: @escaping (String?) -> Void) {
        let pass = password
        guard pass.count >= 8 else {
            completion("No WiFi password was built into the app. Join \"\(ssid)\" in Settings > Wi-Fi.")
            return
        }
        let config = NEHotspotConfiguration(ssid: ssid, passphrase: pass, isWEP: false)
        config.joinOnce = false  // stay joined even though the network has no internet
        NEHotspotConfigurationManager.shared.apply(config) { error in
            DispatchQueue.main.async {
                if let error = error as NSError? {
                    if error.domain == NEHotspotConfigurationErrorDomain,
                       error.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                        completion(nil)
                    } else {
                        completion("Could not join \(ssid): \(error.localizedDescription)")
                    }
                } else {
                    completion(nil)
                }
            }
        }
    }
}
