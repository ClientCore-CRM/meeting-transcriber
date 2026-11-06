import Foundation
@testable import MeetingTranscriber
import XCTest

final class BoostyAPIClientTests: XCTestCase {
    func testOnlyHTTPSOriginsAreAccepted() throws {
        XCTAssertThrowsError(try BoostyAPIClient(origin: "http://meets.clientcore.ru"))
        XCTAssertThrowsError(try BoostyAPIClient(origin: "https://user:secret@meets.clientcore.ru"))
        XCTAssertThrowsError(try BoostyAPIClient(origin: "https://meets.clientcore.ru/other"))
        let client = try BoostyAPIClient(origin: "https://meets.clientcore.ru/")
        XCTAssertEqual(client.origin, "https://meets.clientcore.ru")
    }

    func testPKCEUsesS256AndNeverSendsVerifierToBrowser() {
        let pair = BoostyPKCE.make()
        XCTAssertGreaterThanOrEqual(pair.verifier.count, 43)
        XCTAssertEqual(pair.challenge.count, 43)
        XCTAssertNotEqual(pair.verifier, pair.challenge)
        XCTAssertEqual(BoostyPKCE.challenge(for: pair.verifier), pair.challenge)
    }

    func testRequestsUseOnlyScopedDeviceAuthorization() throws {
        let client = try BoostyAPIClient(origin: "https://meets.clientcore.ru")
        let request = try client.makeRequest(path: "/api/desktop/recordings/start", method: "POST", token: "device-test", body: Data("{}".utf8))
        XCTAssertEqual(request.url?.host, "meets.clientcore.ru")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer device-test")
        XCTAssertNil(request.url?.query)
        XCTAssertThrowsError(try client.makeRequest(path: "https://evil.example", method: "POST", token: "test"))
        XCTAssertFalse(try BoostyAPIClient.sameOrigin(XCTUnwrap(URL(string: "https://evil.example")), XCTUnwrap(URL(string: client.origin))))
        XCTAssertFalse(try BoostyAPIClient.sameOrigin(XCTUnwrap(URL(string: "http://meets.clientcore.ru")), XCTUnwrap(URL(string: client.origin))))
    }
}
