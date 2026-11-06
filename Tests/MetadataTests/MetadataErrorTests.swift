import Testing

@testable import Fixtures
@testable import Metadata

@Test func everyKindOfMetadataErrorHasAPlainMessage() {
    for kind in MetadataError.Kind.allCases {
        let error = MetadataError(
            path: "/m/a.dsf", kind: kind, offset: 12, detail: "the 'fmt ' chunk is 3 bytes")
        #expect(readsAsPlainText(error.userMessage), "\(kind): \(error.userMessage)")
        #expect(!error.userMessage.contains("/m/a.dsf"))
    }
}
