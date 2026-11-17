import Foundation
import Testing

@testable import OpenDDCamKit

@Suite struct CameraErrorTests {
    @Test(arguments: [1996488765, 1996488770, 1996488773])
    func sessionCodes(code: Int) {
        let error = CameraError(errcode: code)
        #expect(error == .sessionExpired(code: code))
        #expect(error?.isSessionError == true)
    }

    @Test func otherCodes() {
        #expect(CameraError(errcode: 1996488783) == .tooManyConnections)
        #expect(CameraError(errcode: 1996488784) == .loginRejected(code: 1996488784))
        #expect(CameraError(errcode: 1996488789) == .loginRejected(code: 1996488789))
        #expect(CameraError(errcode: 1996488797) == .notAllowedWhileDriving)
        #expect(CameraError(errcode: 12345) == .camera(code: 12345))
    }

    @Test func zeroIsNotAnError() {
        #expect(CameraError(errcode: 0) == nil)
    }

    @Test func nonSessionErrorsAreNotSessionErrors() {
        #expect(CameraError.tooManyConnections.isSessionError == false)
        #expect(CameraError.notAllowedWhileDriving.isSessionError == false)
        #expect(CameraError.camera(code: 7).isSessionError == false)
    }
}

@Suite struct JSONValueTests {
    @Test func tolerantInt() {
        #expect(JSONValue.number(5).int == 5)
        #expect(JSONValue.string(" 42 ").int == 42)
        #expect(JSONValue.string("3.0").int == 3)
        #expect(JSONValue.number(1.5).int == nil)
        #expect(JSONValue.string("abc").int == nil)
        #expect(JSONValue.bool(true).int == nil)
        #expect(JSONValue.null.int == nil)
        #expect(JSONValue.number(1e30).int == nil)
    }

    @Test func tolerantString() {
        #expect(JSONValue.string("x").string == "x")
        #expect(JSONValue.number(7).string == "7")
        #expect(JSONValue.null.string == nil)
    }

    @Test func bigErrcodeSurvives() {
        #expect(JSONValue(data: Data("1996488765".utf8))?.int == 1996488765)
    }

    @Test func distinguishesBoolFromNumber() {
        let v = JSONValue(data: Data(#"{"a":true,"b":1}"#.utf8))
        #expect(v?["a"] == .bool(true))
        #expect(v?["b"] == .number(1))
    }

    @Test func roundTripEncoding() throws {
        let value = JSONValue.object(["k": .array([.number(1), .string("a"), .null, .bool(false)])])
        let decoded = JSONValue(data: value.encoded())
        #expect(decoded == value)
    }

    @Test func invalidJSONIsNil() {
        #expect(JSONValue(data: Data("{oops".utf8)) == nil)
        #expect(JSONValue(data: Data()) == nil)
    }
}

@Suite struct ResponseParserTests {
    @Test func dataAsObject() {
        let r = Fixture.response("session")
        #expect(r.errcode == 0)
        #expect(r.isJSON)
        #expect(r.dataWasString == false)
        #expect(r.payload["acSessionId"]?.string == "0123456789abcdef")
    }

    @Test func dataAsStringWithJSON() {
        let r = Fixture.response("base_info_string_data")
        #expect(r.errcode == 0)
        #expect(r.dataWasString)
        #expect(r.payload["model"]?.string == "VOLVO D317")
    }

    @Test func dataStringThatIsNotJSONStaysAString() {
        let r = CameraResponse.parse(Data(#"{"errcode":0,"data":"hello"}"#.utf8))
        #expect(r.dataWasString == false)
        #expect(r.root?["data"] == .string("hello"))
        #expect(r.payload["data"]?.string == "hello")
    }

    @Test func emptyDataFallsBackToWholeObject() {
        let r = CameraResponse.parse(Data(#"{"errcode":0,"num":3}"#.utf8))
        #expect(r.payload["num"]?.int == 3)
    }

    @Test func errcodeOnly() {
        let r = Fixture.response("session_expired")
        #expect(r.errcode == 1996488765)
        #expect(r.isJSON)
    }

    @Test func errcodeAsString() {
        let r = CameraResponse.parse(Data(#"{"errcode":"1996488783"}"#.utf8))
        #expect(r.errcode == 1996488783)
    }

    @Test func notJSON() {
        let r = CameraResponse.parse(Data("<html>nope</html>".utf8))
        #expect(r.isJSON == false)
        #expect(r.errcode == nil)
        #expect(r.rawText == "<html>nope</html>")
        #expect(r.payload.isEmpty)
    }

    @Test func topLevelListDoesNotCrash() {
        let r = CameraResponse.parse(Data("[1,2,3]".utf8))
        #expect(r.isJSON)
        #expect(r.errcode == nil)
        #expect(r.payload.isEmpty)
    }

    @Test func emptyBodyAndInvalidUTF8() {
        #expect(CameraResponse.parse(Data()).isJSON == false)
        let r = CameraResponse.parse(Data([0xFF, 0xFE, 0x7B]))
        #expect(r.isJSON == false)
    }

    @Test func nullData() {
        let r = CameraResponse.parse(Data(#"{"errcode":0,"data":null}"#.utf8))
        #expect(r.errcode == 0)
        #expect(r.payload["errcode"]?.int == 0)
    }
}
