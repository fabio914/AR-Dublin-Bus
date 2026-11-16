import Testing
@testable import ARDublinBus

struct BuildSecretTests {
    @Test func decodesWhatTheBuildScriptWrites() {
        // "abc": 97 + 91, 98 + 128, (99 + 165) mod 256 — the arithmetic in project.yml's script.
        #expect(BuildSecretCoding.decode([188, 226, 8]) == "abc")
    }

    @Test func roundTrips() {
        let key = "4bf2-EXAMPLE-key_0123456789abcdefABCDEF"
        #expect(BuildSecretCoding.encode(key) != Array(key.utf8))
        #expect(BuildSecretCoding.decode(BuildSecretCoding.encode(key)) == key)
    }

    @Test func noKeyMeansNil() {
        #expect(BuildSecretCoding.decode([]) == nil)
    }

    @Test func bundledKeyMatchesTheBuildSetting() {
        // The generated file and the decoder agree, whatever key (or none) this build has.
        #expect(APIKeyStore.bundledKey == BuildSecretCoding.decode(BuildSecrets.scrambledNTAAPIKey))
        #expect(APIKeyStore.bundledKey?.isEmpty != true)
    }
}
