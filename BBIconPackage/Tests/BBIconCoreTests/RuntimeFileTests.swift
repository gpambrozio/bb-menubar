import Foundation
import Testing
@testable import BBIconCore

struct RuntimeFileTests {
    /// The shape bb 0.44.0 writes, as recorded in the spec.
    static let recorded = #"""
    { "entryPath": "/Applications/bb.app/Contents/Resources/bb-app-bridge.mjs", "pid": 16746,
      "serverUrl": "http://127.0.0.1:38886", "startedAt": "2026-09-29T12:00:00.000Z",
      "surface": "desktop", "version": "0.44.0" }
    """#

    static func json(pid: String = "16746", serverUrl: String = #""http://127.0.0.1:38886""#) -> Data {
        Data(#"{"pid": \#(pid), "serverUrl": \#(serverUrl)}"#.utf8)
    }

    /// The detail of the `.malformed` error `parse` throws, or nil if it did not throw that.
    static func malformedDetail(_ data: Data) -> String? {
        do {
            _ = try RuntimeFile.parse(data)
            return nil
        } catch RuntimeFileError.malformed(let detail) {
            return detail
        } catch {
            return nil
        }
    }

    @Test("parses the shape bb writes")
    func parsesRecordedShape() throws {
        let info = try RuntimeFile.parse(Data(Self.recorded.utf8))
        #expect(info.pid == 16746)
        #expect(info.serverURL == URL(string: "http://127.0.0.1:38886"))
        #expect(info.version == "0.44.0")
    }

    @Test("version is optional, and a version that is not a string is dropped")
    func versionIsOptional() throws {
        #expect(try RuntimeFile.parse(Self.json()).version == nil)
        let numeric = Data(#"{"pid": 1, "serverUrl": "https://bb.example", "version": 44}"#.utf8)
        #expect(try RuntimeFile.parse(numeric).version == nil)
    }

    @Test("a missing pid is named")
    func rejectsMissingPid() {
        let data = Data(#"{"serverUrl": "http://127.0.0.1:38886"}"#.utf8)
        #expect(Self.malformedDetail(data) == "pid is missing")
    }

    @Test("a pid outside 1...Int32.max is rejected, not truncated", arguments: ["0", "-1", "9999999999", "2147483648"])
    func rejectsPidOutOfRange(pid: String) {
        #expect(Self.malformedDetail(Self.json(pid: pid)) == "pid is not a whole number from 1 to 2147483647")
    }

    @Test("a pid that is not a whole number is rejected", arguments: ["1.5", #""16746""#, "true", "false", "null", "[1]"])
    func rejectsNonIntegerPid(pid: String) {
        #expect(Self.malformedDetail(Self.json(pid: pid)) == "pid is not a whole number from 1 to 2147483647")
    }

    @Test("the largest pid a pid_t holds is accepted")
    func acceptsInt32Max() throws {
        #expect(try RuntimeFile.parse(Self.json(pid: "2147483647")).pid == Int32.max)
    }

    @Test("a missing serverUrl is named")
    func rejectsMissingServerURL() {
        #expect(Self.malformedDetail(Data(#"{"pid": 1}"#.utf8)) == "serverUrl is missing")
    }

    @Test(
        "a serverUrl that is not http or https with a host is rejected",
        arguments: [#""ftp://x""#, #""ws://127.0.0.1:38886""#, #""http://""#, #""127.0.0.1:38886""#, #""""#, "38886", "null"]
    )
    func rejectsNonHTTPServerURL(serverUrl: String) {
        #expect(Self.malformedDetail(Self.json(serverUrl: serverUrl)) == "serverUrl is not an http or https URL with a host")
    }

    @Test("an https serverUrl with a path is accepted as written")
    func acceptsHTTPSWithPath() throws {
        let info = try RuntimeFile.parse(Self.json(serverUrl: #""HTTPS://bb.example/base""#))
        #expect(info.serverURL == URL(string: "HTTPS://bb.example/base"))
    }

    @Test("a file that is not a JSON object is named", arguments: ["", "not json", "[]", "16746", #"{"pid": 1"#])
    func rejectsNonObject(text: String) {
        #expect(Self.malformedDetail(Data(text.utf8)) == "it is not a JSON object")
    }

    @Test("the error names the runtime file")
    func errorMessage() {
        #expect(RuntimeFileError.malformed("pid is missing").message == "bb's runtime file could not be read: pid is missing")
        #expect(errorText(RuntimeFileError.unreadable("denied")) == "bb's runtime file could not be read: denied")
    }

    @Test("the directory is ~/.bb")
    func directory() {
        #expect(RuntimeFile.directory(home: "/Users/x") == "/Users/x/.bb")
        #expect(RuntimeFile.fileName == "bb-app-runtime.json")
    }

    @Test("the watch passes the runtime file and its atomic-write temp, nothing else in ~/.bb")
    func runtimeFileEventFilter() {
        #expect(RuntimeFile.isRuntimeFileEvent("/Users/x/.bb/bb-app-runtime.json"))
        #expect(RuntimeFile.isRuntimeFileEvent("/Users/x/.bb/bb-app-runtime.json.tmp-123"))
        #expect(!RuntimeFile.isRuntimeFileEvent("/Users/x/.bb/bb.db-wal"))
        #expect(!RuntimeFile.isRuntimeFileEvent("/Users/x/.bb/bb.db"))
        #expect(!RuntimeFile.isRuntimeFileEvent("/Users/x/.bb/thread-storage/bb-app-runtime.json/other"))
    }
}
