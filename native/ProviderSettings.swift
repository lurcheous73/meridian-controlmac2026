import Foundation

struct ProviderSettings {
    private static func enabled(_ key: String, defaultValue: Bool) -> Bool {
        let d = UserDefaults.standard
        return d.object(forKey: key) == nil ? defaultValue : d.bool(forKey: key)
    }

    static var musicBrainzEnabled: Bool {
        enabled("metadataMusicBrainzEnabled", defaultValue: true)
    }

    static var audioDBEnabled: Bool {
        enabled("metadataAudioDBEnabled", defaultValue: true)
    }

    static var bandcampEnabled: Bool {
        enabled("metadataBandcampEnabled", defaultValue: true)
    }

    static var discogsEnabled: Bool {
        enabled("metadataDiscogsEnabled", defaultValue: false)
    }
    static var audioDBKey: String {
        SecretStore.load(service: "uk.controlmac2026.audiodb") ?? "123"
    }

    static var discogsToken: String? {
        SecretStore.load(service: "uk.controlmac2026.discogs")
    }
}
