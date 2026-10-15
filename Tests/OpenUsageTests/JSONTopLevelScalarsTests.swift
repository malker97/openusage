import XCTest
@testable import OpenUsage

/// The cheap top-level field reader the log parsers use to follow a transcript without decoding every
/// line: it must only ever report the object's own fields, however the nested content is shaped.
final class JSONTopLevelScalarsTests: XCTestCase {
    private func values(_ json: String, _ keys: [String]) -> [String: String] {
        JSONTopLevelScalars.values(in: Data(json.utf8), keys: keys)
    }

    func testReadsTopLevelStringsAndNumbers() {
        let line = #"{"type":"system","retryInMs":559,"offset":-1.5e3,"uuid":"u-1","timestamp":"2026-10-15T07:00:00.000Z"}"#
        XCTAssertEqual(values(line, ["uuid", "timestamp", "retryInMs", "offset", "type"]), [
            "uuid": "u-1", "timestamp": "2026-10-15T07:00:00.000Z", "retryInMs": "559", "offset": "-1.5e3",
            "type": "system"
        ])
    }

    func testNestedFieldsWithTheSameNamesAreIgnored() {
        // Tool inputs and results are arbitrary JSON, so a nested `uuid`/`timestamp` can come first.
        let line = """
        {"parentUuid":"p-1","message":{"content":[{"type":"tool_use","input":{"uuid":"nested","timestamp":"1999-01-01"}},\
        "a \\"quoted\\" {brace} [bracket]"]},"uuid":"u-2","timestamp":"2026-10-15T07:00:01.000Z",\
        "toolUseResult":{"timestamp":"later"}}
        """
        XCTAssertEqual(values(line, ["uuid", "timestamp", "parentUuid"]), [
            "parentUuid": "p-1", "uuid": "u-2", "timestamp": "2026-10-15T07:00:01.000Z"
        ])
    }

    func testSkipsNullBooleansContainersAndEscapedStrings() {
        let line = #"{"parentUuid":null,"isSidechain":true,"uuid":{"id":"x"},"type":"us\u0065r","requestId":"r-1"}"#
        XCTAssertEqual(values(line, ["parentUuid", "isSidechain", "uuid", "type", "requestId"]), ["requestId": "r-1"])
    }

    func testFirstOccurrenceWinsAndUnrequestedKeysAreSkipped() {
        let line = #"{"uuid":"first","other":[1,{"uuid":"deep"}],"uuid":"second","missing":null}"#
        XCTAssertEqual(values(line, ["uuid", "missing"]), ["uuid": "first"])
    }

    func testMalformedLinesKeepWhatWasReadBeforeTheDamage() {
        XCTAssertEqual(values(#"{"uuid":"u-3","message":{"content":"unterminated"#, ["uuid", "timestamp"]), ["uuid": "u-3"])
        XCTAssertEqual(values(#"["uuid","u-4"]"#, ["uuid"]), [:])
        XCTAssertEqual(values("not json", ["uuid"]), [:])
        XCTAssertEqual(values("", ["uuid"]), [:])
    }

    func testReadsFromADataSliceWithAnOffsetStart() {
        let file = Data(#"{"uuid":"a"}"#.utf8) + Data("\n".utf8) + Data(#" { "uuid" : "b" , "x" : 1 } "#.utf8)
        let lines = file.split(separator: UInt8(ascii: "\n"))
        XCTAssertEqual(JSONTopLevelScalars.values(in: lines[1], keys: ["uuid", "x"]), ["uuid": "b", "x": "1"])
    }
}
