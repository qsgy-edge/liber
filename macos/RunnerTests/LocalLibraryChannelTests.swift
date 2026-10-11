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

  func testMovedRootResolvesPersistedChildKeyWithoutRelisting() throws {
    root = try XCTUnwrap(invoke("inspectRoot", ["root": root as Any, "writable": false]) as? [String: Any])
    let child = rootURL.appendingPathComponent("texts/book.txt")
    try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("book after root move".utf8).write(to: child)
    var persisted = rooted(child)
    persisted["key"] = "texts/book.txt"
    let movedRoot = scratch.appendingPathComponent("another-parent/renamed-managed", isDirectory: true)
    try FileManager.default.createDirectory(at: movedRoot.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: rootURL, to: movedRoot)

    // Refresh only the root bookmark. Keep the persisted child locator and root receipt unchanged.
    let refreshed = try XCTUnwrap(invoke("inspectRoot", ["root": root as Any, "writable": false]) as? [String: Any])
    let movedChild = movedRoot.appendingPathComponent("texts/book.txt").resolvingSymlinksInPath()
    let info = try XCTUnwrap(invoke("stat", ["root": refreshed, "file": persisted]) as? [String: Any])
    let locator = try XCTUnwrap(info["locator"] as? String)
    XCTAssertEqual(try XCTUnwrap(URL(string: locator)).resolvingSymlinksInPath(), movedChild)
    XCTAssertEqual(info["key"] as? String, "texts/book.txt")
    XCTAssertEqual(persisted["locator"] as? String, child.absoluteString)
    let lease = try XCTUnwrap(invoke("acquireRead", ["root": refreshed, "file": persisted]) as? [String: Any])
    XCTAssertEqual(try String(contentsOfFile: XCTUnwrap(lease["path"] as? String), encoding: .utf8), "book after root move")
    XCTAssertNil(invoke("releaseRead", ["token": try XCTUnwrap(lease["token"] as? String)]))
  }

  func testRootedKeysRejectTraversalEmptyComponentsAndSymlinkEscape() throws {
    let outside = scratch.appendingPathComponent("outside.txt")
    try Data("retain outside".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("escape"), withDestinationURL: scratch)
    try FileManager.default.createSymbolicLink(at: rootURL.appendingPathComponent("linked.txt"), withDestinationURL: outside)
    for key in ["", "/outside.txt", "../outside.txt", "nested/../outside.txt", "./outside.txt",
                "nested//book.txt", "nested/", "outside.txt\0ignored", "escape/outside.txt", "linked.txt"] {
      var receipt = rooted(rootURL.appendingPathComponent("book.txt"))
      receipt["key"] = key
      for method in ["stat", "acquireRead", "deleteFile"] {
        XCTAssertEqual((invoke(method, ["root": root as Any, "file": receipt]) as? FlutterError)?.code, "permission", "\(method): \(key)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: outside), Data("retain outside".utf8))
  }

  func testRootedReceiptCannotBeReinterpretedUnderAnotherAuthorizedRoot() throws {
    root = try XCTUnwrap(invoke("inspectRoot", ["root": root as Any, "writable": false]) as? [String: Any])
    let original = rootURL.appendingPathComponent("book.txt")
    try Data("original root".utf8).write(to: original)
    let otherURL = scratch.appendingPathComponent("other-managed", isDirectory: true)
    try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
    let otherChild = otherURL.appendingPathComponent("book.txt")
    try Data("other root".utf8).write(to: otherChild)
    let otherRoot: [String: Any] = ["kind": "apple", "locator": otherURL.absoluteString, "authorization": try authorization(otherURL)]
    for method in ["stat", "acquireRead", "deleteFile"] {
      XCTAssertEqual((invoke(method, ["root": otherRoot, "file": rooted(original)]) as? FlutterError)?.code, "permission")
    }
    XCTAssertEqual(try Data(contentsOf: original), Data("original root".utf8))
    XCTAssertEqual(try Data(contentsOf: otherChild), Data("other root".utf8))
  }

  func testRootlessLegacyReceiptCannotSelectManagedSibling() throws {
    let outside = scratch.appendingPathComponent("original.txt")
    let managed = rootURL.appendingPathComponent("original.txt")
    try Data("legacy original".utf8).write(to: outside)
    try Data("managed sibling".utf8).write(to: managed)
    // Obtain the actual legacy receipt shape from standalone native stat, without a source grant.
    let legacy = try XCTUnwrap(invoke("stat", ["file": ["locator": outside.absoluteString]]) as? [String: Any])
    XCTAssertNil(legacy["authorization"])
    XCTAssertNil(legacy["root"])
    XCTAssertEqual(legacy["key"] as? String, "original.txt")
    XCTAssertNil(invoke("fileInRoot", ["root": root as Any, "file": legacy]))
    for method in ["stat", "acquireRead", "deleteFile"] {
      let result = invoke(method, ["root": root as Any, "file": legacy])
      // A failing pre-fix read must not hold coordination while the deletion counterexample runs.
      if let lease = result as? [String: Any], let token = lease["token"] as? String {
        _ = invoke("releaseRead", ["token": token])
      }
      XCTAssertEqual((result as? FlutterError)?.code, "permission", method)
      XCTAssertEqual(try Data(contentsOf: outside), Data("legacy original".utf8))
      XCTAssertEqual(try Data(contentsOf: managed), Data("managed sibling".utf8))
    }
    let originalLease = try XCTUnwrap(invoke("acquireRead", ["file": legacy]) as? [String: Any])
    XCTAssertEqual(try String(contentsOfFile: XCTUnwrap(originalLease["path"] as? String), encoding: .utf8), "legacy original")
    XCTAssertNil(invoke("releaseRead", ["token": try XCTUnwrap(originalLease["token"] as? String)]))

    let rootlessManaged = try XCTUnwrap(invoke("stat", ["file": ["locator": managed.absoluteString]]) as? [String: Any])
    let canonical = try XCTUnwrap(invoke("fileInRoot", ["root": root as Any, "file": rootlessManaged]) as? [String: Any])
    XCTAssertNotNil(canonical["root"] as? [String: Any])
    XCTAssertNil(canonical["authorization"])
    XCTAssertNotNil(invoke("stat", ["root": root as Any, "file": canonical]) as? [String: Any])
    let managedLease = try XCTUnwrap(invoke("acquireRead", ["root": root as Any, "file": canonical]) as? [String: Any])
    XCTAssertEqual(try String(contentsOfFile: XCTUnwrap(managedLease["path"] as? String), encoding: .utf8), "managed sibling")
    XCTAssertNil(invoke("releaseRead", ["token": try XCTUnwrap(managedLease["token"] as? String)]))
  }

  func testClaimedRootIdentityCannotOverrideContradictoryBookmark() throws {
    root = try XCTUnwrap(invoke("inspectRoot", ["root": root as Any, "writable": false]) as? [String: Any])
    let original = rootURL.appendingPathComponent("book.txt")
    try Data("root A".utf8).write(to: original)
    let otherURL = scratch.appendingPathComponent("other-managed", isDirectory: true)
    try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
    let otherChild = otherURL.appendingPathComponent("book.txt")
    try Data("root B".utf8).write(to: otherChild)
    let otherInput: [String: Any] = ["kind": "apple", "locator": otherURL.absoluteString, "authorization": try authorization(otherURL)]
    let otherRoot = try XCTUnwrap(invoke("inspectRoot", ["root": otherInput, "writable": false]) as? [String: Any])
    let targetIdentity = try XCTUnwrap(otherRoot["identity"] as? String)
    XCTAssertNotEqual(root["identity"] as? String, targetIdentity)
    var receipt = try XCTUnwrap(invoke("stat", ["root": root as Any, "file": rooted(original)]) as? [String: Any])
    var contradictoryRoot = try XCTUnwrap(receipt["root"] as? [String: Any])
    // Only falsify the identity metadata; the embedded bookmark/locator still identify A.
    contradictoryRoot["identity"] = targetIdentity
    receipt["root"] = contradictoryRoot
    for method in ["stat", "acquireRead", "deleteFile"] {
      let result = invoke(method, ["root": otherRoot, "file": receipt])
      if let lease = result as? [String: Any], let token = lease["token"] as? String {
        _ = invoke("releaseRead", ["token": token])
      }
      XCTAssertEqual((result as? FlutterError)?.code, "permission", method)
      XCTAssertEqual(try Data(contentsOf: original), Data("root A".utf8))
      XCTAssertEqual(try Data(contentsOf: otherChild), Data("root B".utf8))
    }
  }

  func testInvalidAuthorizationAndOutsideRootDeletionRemainVisible() throws {
    var revoked = root!
    revoked["authorization"] = "not-a-bookmark"
    XCTAssertEqual((invoke("inspectRoot", ["root": revoked, "writable": true]) as? FlutterError)?.code, "permission")
    let outside = scratch.appendingPathComponent("original.txt")
    try Data("retain".utf8).write(to: outside)
    let sameName = rootURL.appendingPathComponent("original.txt")
    try Data("retain managed sibling".utf8).write(to: sameName)
    for method in ["stat", "acquireRead", "deleteFile"] {
      XCTAssertEqual((invoke(method, ["root": root as Any, "file": try source(outside)]) as? FlutterError)?.code, "permission")
    }
    XCTAssertEqual(try Data(contentsOf: outside), Data("retain".utf8))
    XCTAssertEqual(try Data(contentsOf: sameName), Data("retain managed sibling".utf8))
    let originalLease = try XCTUnwrap(invoke("acquireRead", ["file": try source(outside)]) as? [String: Any])
    XCTAssertEqual(try String(contentsOfFile: XCTUnwrap(originalLease["path"] as? String), encoding: .utf8), "retain")
    XCTAssertNil(invoke("releaseRead", ["token": try XCTUnwrap(originalLease["token"] as? String)]))
    let canonical = try XCTUnwrap(invoke("fileInRoot", ["root": root as Any, "file": try source(sameName)]) as? [String: Any])
    XCTAssertNil(canonical["authorization"])
    XCTAssertNotNil(invoke("stat", ["root": root as Any, "file": canonical]) as? [String: Any])
    XCTAssertNil(invoke("stat", ["root": root as Any, "file": rooted(rootURL.appendingPathComponent("missing.txt"))]))
  }
}
