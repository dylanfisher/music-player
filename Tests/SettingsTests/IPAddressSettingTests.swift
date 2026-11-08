import Testing

@testable import Settings

private let schema = AppSettings()

private func parsed(_ text: String) throws(ConfigErrorList) -> ConfigContents {
    try ConfigFile.parse(
        ConfigText(text), settings: schema.settings, check: { _, _, _ in nil },
        conflicts: schema.conflicts)
}

@Test func receiverControlIsOffAndHasNoAddressByDefault() {
    #expect(schema.receiverEnabled.defaultValue == false)
    #expect(schema.receiverAddress.defaultValue == nil)
}

@Test func aIPAddressSettingIsALiteralAndNeverAName() throws {
    for text in ["192.0.2.10", "2001:db8::10", "fe80::1%4"] {
        let values = try parsed(#"{"receiver.address": "\#(text)"}"#).values
        #expect((values["receiver.address"] as? IPAddressSetting)?.address != nil, "\(text)")
    }
    #expect(try parsed(#"{"receiver.address": null}"#).values["receiver.address"] != nil)
    for text in ["denon.local", "avr", "192.0.2", "http://192.0.2.10", "192.0.2.10:23", ""] {
        #expect(throws: ConfigErrorList.self, "\(text)") {
            try parsed(#"{"receiver.address": "\#(text)"}"#)
        }
    }
    #expect(throws: ConfigErrorList.self) { try parsed(#"{"receiver.address": 23}"#) }
}
