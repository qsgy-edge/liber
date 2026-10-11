import Foundation
import CryptoKit
import XCTest
#if os(macOS)
import FlutterMacOS
@testable import liber
#else
import Flutter
@testable import Runner
#endif

/// Runs against real native IO in the test host's private scratch directory.
/// These rows do not exercise native pickers, external providers, or persisted-grant restarts.
final class LocalLibraryChannelTests: XCTestCase {
  private var channel: LocalLibraryChannel!
  private var scratch: URL!
  private var rootURL: URL!
  private var root: [String: Any]!
  private var leaseTokens: Set<String> = []

  override func setUpWithError() throws {
    channel = LocalLibraryChannel()
    scratch = FileManager.default.temporaryDirectory.appendingPathComponent("liber-native-access-" + UUID().uuidString, isDirectory: true)
    rootURL = scratch.appendingPathComponent("managed", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    root = ["kind": "apple", "locator": rootURL.absoluteString, "authorization": try authorization(rootURL)]
  }

  override func tearDownWithError() throws {
    for token in leaseTokens { _ = invoke("releaseRead", ["token": token]) }
    try FileManager.default.removeItem(at: scratch)
    channel = nil
  }

  private func authorization(_ url: URL) throws -> String {
    #if os(macOS)
    let options: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
    let options: URL.BookmarkCreationOptions = []
    #endif
    return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
  }

  private func source(_ url: URL) throws -> [String: Any] {
    return ["locator": url.absoluteString, "key": url.lastPathComponent, "name": url.lastPathComponent,
      "directory": false, "authorization": try authorization(url)]
  }

  private func rooted(_ url: URL) -> [String: Any] {
    return ["locator": url.absoluteString, "key": url.lastPathComponent, "name": url.lastPathComponent,
      "directory": false, "root": root as Any]
  }

  private func invoke(_ method: String, _ args: [String: Any]) -> Any? {
    let finished = expectation(description: method)
    var answer: Any?
    channel.handle(FlutterMethodCall(methodName: method, arguments: args)) { result in
      answer = result
      finished.fulfill()
    }
    wait(for: [finished], timeout: 10)
    if method == "acquireRead", let map = answer as? [String: Any], let token = map["token"] as? String { leaseTokens.insert(token) }
    if method == "releaseRead", let token = args["token"] as? String { leaseTokens.remove(token) }
    return answer
  }

  func testCopyVerifiesExactBytesAndRetainsOriginal() throws {
    let url = scratch.appendingPathComponent("source.txt")
    let bytes = Data((0..<150_003).map { UInt8($0 % 251) })
    try bytes.write(to: url)
    let result = try XCTUnwrap(invoke("copyFile", ["source": try source(url), "destinationRoot": root as Any,
      "name": "book.txt", "operationId": UUID().uuidString]) as? [String: Any])
    XCTAssertEqual(result["verified"] as? Bool, true)
    XCTAssertEqual(result["bytesCopied"] as? Int64, Int64(bytes.count))
    XCTAssertEqual(result["sha256"] as? String, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    XCTAssertEqual(try Data(contentsOf: rootURL.appendingPathComponent("book.txt")), bytes)
    XCTAssertEqual(try Data(contentsOf: url), bytes)
    let file = try XCTUnwrap(result["file"] as? [String: Any])
    XCTAssertEqual(file["key"] as? String, "book.txt")
    XCTAssertEqual(file["locator"] as? String, rootURL.appendingPathComponent("book.txt").absoluteString)
  }

  func testExclusiveCopyDoesNotTruncateExistingFileOrSourceAlias() throws {
    let url = scratch.appendingPathComponent("source.txt")
    try Data("new".utf8).write(to: url)
    let destination = rootURL.appendingPathComponent("book.txt")
    try Data("previous".utf8).write(to: destination)
    let args: [String: Any] = ["source": try source(url), "destinationRoot": root as Any,
      "name": "book.txt", "operationId": UUID().uuidString]
    XCTAssertEqual((invoke("copyFile", args) as? FlutterError)?.code, "collision")
    XCTAssertEqual(try Data(contentsOf: destination), Data("previous".utf8))
    try FileManager.default.removeItem(at: destination)
    try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: url)
    var aliasArgs = args; aliasArgs["operationId"] = UUID().uuidString
    XCTAssertEqual((invoke("copyFile", aliasArgs) as? FlutterError)?.code, "collision")
    XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
  }

  func testCancellationRemovesOnlyOwnedPartialAndProgressRemainsAvailable() throws {
    let url = scratch.appendingPathComponent("source.txt")
    try Data(repeating: 0x41, count: 16 * 1024 * 1024).write(to: url)
    let survivor = rootURL.appendingPathComponent("unrelated.txt")
    try Data("retain".utf8).write(to: survivor)
    let id = UUID().uuidString
    let copied = expectation(description: "copy cancelled")
    var answer: Any?
    channel.handle(FlutterMethodCall(methodName: "copyFile", arguments: ["source": try source(url),
      "destinationRoot": root as Any, "name": "partial.txt", "operationId": id])) { result in
      answer = result; copied.fulfill()
    }
    channel.handle(FlutterMethodCall(methodName: "cancel", arguments: ["operationId": id])) { result in
      XCTAssertNil(result)
    }
    wait(for: [copied], timeout: 10)
    XCTAssertEqual((answer as? FlutterError)?.code, "cancelled")
    XCTAssertFalse(FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("partial.txt").path))
    XCTAssertEqual(try Data(contentsOf: survivor), Data("retain".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    XCTAssertNotNil(invoke("progress", ["operationId": id]) as? [String: Any])
  }

  func testIndependentReadLeasesReleaseWithoutBlockingTheCoordinator() throws {
    let url = rootURL.appendingPathComponent("book.txt")
    try Data("read lease".utf8).write(to: url)
    let first = try XCTUnwrap(invoke("acquireRead", ["root": root as Any, "file": rooted(url)]) as? [String: Any])
    let second = try XCTUnwrap(invoke("acquireRead", ["root": root as Any, "file": rooted(url)]) as? [String: Any])
    let firstToken = try XCTUnwrap(first["token"] as? String)
    let secondToken = try XCTUnwrap(second["token"] as? String)
    XCTAssertNotEqual(firstToken, secondToken)
    XCTAssertNil(first["fd"])
    XCTAssertEqual(try String(contentsOfFile: XCTUnwrap(first["path"] as? String), encoding: .utf8), "read lease")
    XCTAssertNil(invoke("releaseRead", ["token": firstToken]))
    XCTAssertEqual(try String(contentsOfFile: XCTUnwrap(second["path"] as? String), encoding: .utf8), "read lease")
    XCTAssertNil(invoke("releaseRead", ["token": secondToken]))
    XCTAssertEqual((invoke("releaseRead", ["token": firstToken]) as? FlutterError)?.code, "missing")
  }

  func testLocalReplacementRetainsExactPreviousBytesAndNoClobberRenameRefusesCollision() throws {
    let existing = rootURL.appendingPathComponent("book.txt")
    let staged = rootURL.appendingPathComponent("staged.txt")
    try Data("previous bytes".utf8).write(to: existing)
    try Data("verified new bytes".utf8).write(to: staged)
    XCTAssertEqual((invoke("renameFile", ["root": root as Any, "file": rooted(staged), "name": "book.txt"]) as? FlutterError)?.code, "collision")
    XCTAssertEqual(try Data(contentsOf: existing), Data("previous bytes".utf8))
    let replacement = try XCTUnwrap(invoke("replaceFile", ["root": root as Any, "existing": rooted(existing),
      "staged": rooted(staged), "backupName": "previous.txt", "operationId": UUID().uuidString]) as? [String: Any])
    XCTAssertNotNil(replacement["previous"] as? [String: Any])
    XCTAssertEqual(try Data(contentsOf: existing), Data("verified new bytes".utf8))
    XCTAssertEqual(try Data(contentsOf: rootURL.appendingPathComponent("previous.txt")), Data("previous bytes".utf8))
  }

  func testInvalidAuthorizationAndOutsideRootDeletionRemainVisible() throws {
    var revoked = root!
    revoked["authorization"] = "not-a-bookmark"
    XCTAssertEqual((invoke("inspectRoot", ["root": revoked, "writable": true]) as? FlutterError)?.code, "permission")
    let outside = scratch.appendingPathComponent("original.txt")
    try Data("retain".utf8).write(to: outside)
    XCTAssertEqual((invoke("deleteFile", ["root": root as Any, "file": try source(outside)]) as? FlutterError)?.code, "permission")
    XCTAssertEqual(try Data(contentsOf: outside), Data("retain".utf8))
    XCTAssertNil(invoke("stat", ["root": root as Any, "file": rooted(rootURL.appendingPathComponent("missing.txt"))]))
  }
}
