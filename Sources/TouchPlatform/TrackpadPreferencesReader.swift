import Foundation
import TouchCore

/// Reads the trackpad's gesture settings from its defaults domain. Synchronizes first, because
/// cfprefsd caches values per process and only writes the plist to disk lazily.
public enum TrackpadPreferencesReader {
    private static var domain: CFString { "com.apple.AppleMultitouchTrackpad" as CFString }

    public static func read() -> TrackpadPreferences {
        CFPreferencesAppSynchronize(domain)
        var values: [String: Any] = [:]
        for key in TrackpadPreferences.keys {
            guard let value = CFPreferencesCopyAppValue(key as CFString, domain) else { continue }
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                values[key] = CFBooleanGetValue((value as! CFBoolean))
            } else if let number = value as? NSNumber {
                values[key] = number.intValue
            }
        }
        return TrackpadPreferences(values: values)
    }
}
