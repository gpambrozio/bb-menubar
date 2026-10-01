import Testing
@testable import BBIconCore

struct ErrorTextTests {
    @Test("a MessageError renders as its own message")
    func messageErrorUsesItsMessage() {
        struct E: MessageError { var message: String { "boom" } }
        #expect(errorText(E()) == "boom")
    }
}
