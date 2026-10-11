import XCTest
@testable import Codechote

final class ScreenViewerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/viewer")

    func testRequestsStayInsideTheViewerFolder() {
        XCTAssertEqual(RemoteDesktopServer.resolve("/", in: root)?.path, "/viewer/rd.html")
        XCTAssertEqual(RemoteDesktopServer.resolve("/core/rfb.js?x=1", in: root)?.path, "/viewer/core/rfb.js")
        XCTAssertNil(RemoteDesktopServer.resolve("/../secret", in: root))
        XCTAssertNil(RemoteDesktopServer.resolve("/core/%2e%2e/secret", in: root))
    }

    func testContentTypes() {
        XCTAssertTrue(RemoteDesktopServer.contentType(for: "/a/rfb.js").hasPrefix("text/javascript"))
        XCTAssertTrue(RemoteDesktopServer.contentType(for: "rd.html").hasPrefix("text/html"))
        XCTAssertEqual(RemoteDesktopServer.contentType(for: "x.bin"), "application/octet-stream")
    }
}
