import Foundation
import CryptoKit
import Darwin
#if os(macOS)
import Cocoa
import FlutterMacOS
import Security
#else
import Flutter
import UIKit
import UniformTypeIdentifiers
#endif

/// Shared Apple SDK implementation. iOS builds this same source through its Runner project.
final class LocalLibraryChannel: NSObject, FlutterPlugin {
  private typealias Map = [String: Any]
  private struct Failure: Error {
    let code: String
    let message: String
    var details: Map? = nil
  }
  private final class CopyJob {
    private let lock = NSLock()
    private var cancelled = false
    private var copied: Int64 = 0
    private var total: Int64?
    var finished = false // Accessed only on the main thread.
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
      lock.lock(); let value = cancelled; lock.unlock()
      if value { throw Failure(code: "cancelled", message: "Copy cancelled") }
    }
    func advance(_ value: Int) { lock.lock(); copied += Int64(value); lock.unlock() }
    func setTotal(_ value: Int64) { lock.lock(); total = value; lock.unlock() }
    func progress() -> Map {
      lock.lock(); defer { lock.unlock() }
      return ["bytesCopied": copied, "totalBytes": total.map { $0 as Any } ?? NSNull()]
    }
  }
  private final class ReadLease {
    let released = DispatchSemaphore(value: 0)
    var releaseResult: FlutterResult? // Main thread only.
  }
  private struct Scope {
    let url: URL
    let started: Bool
    let authorization: String?
    func close() { if started { url.stopAccessingSecurityScopedResource() } }
  }
  private let io = DispatchQueue(label: "liber.local-library.io", qos: .userInitiated)
  private var jobs: [String: CopyJob] = [:] // Main thread only.
  private var leases: [String: ReadLease] = [:] // Main thread only.
  private var pickerResult: FlutterResult?
  private var pickingDirectory = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LocalLibraryChannel()
    #if os(iOS)
    registrar.publish(instance)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    let channel = FlutterMethodChannel(name: "liber/local_library", binaryMessenger: messenger)
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
  }

  private func shutdown() {
    jobs.values.forEach { $0.cancel() }
    leases.values.forEach { $0.released.signal() }
    pickerResult?(FlutterError(code: "cancelled", message: "Application closed", details: nil))
    pickerResult = nil
  }

  #if os(iOS)
  func detachFromEngine(for registrar: FlutterPluginRegistrar) { shutdown() }
  func applicationWillTerminate(_ application: UIApplication) { shutdown() }
  #else
  func handleWillTerminate(_ notification: Notification) { shutdown() }
  #endif

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    do {
      let args = try call.arguments.map { try map($0, "arguments") } ?? [:]
      switch call.method {
      case "pickDirectory", "pickFiles":
        try pick(directory: call.method == "pickDirectory", result: result)
      case "progress":
        guard let job = jobs[try string(args, "operationId")] else { throw missing("Unknown operation") }
        result(job.progress())
      case "cancel":
        guard let job = jobs[try string(args, "operationId")] else { throw missing("Unknown operation") }
        job.cancel(); result(nil)
      case "releaseRead":
        let token = try string(args, "token")
        guard let lease = leases[token], lease.releaseResult == nil else { throw missing("Unknown read lease") }
        lease.releaseResult = result
        // The coordinator waits on its own thread. Release never queues on that thread.
        lease.released.signal()
      case "acquireRead": try acquireRead(args, result: result)
      case "copyFile", "replaceFile":
        let id = try string(args, "operationId")
        guard jobs[id] == nil else { throw Failure(code: "collision", message: "Operation ID already used") }
        for key in jobs.keys.sorted() where jobs.count >= 64 && jobs[key]?.finished == true { jobs.removeValue(forKey: key) }
        let job = CopyJob(); jobs[id] = job
        io.async {
          let answer = self.answer {
            if call.method == "copyFile" { return try self.copy(args, job: job) }
            return try self.replace(args, job: job)
          }
          DispatchQueue.main.async { job.finished = true; result(answer) }
        }
      case "inspectRoot", "list", "stat", "fileInRoot", "fingerprint", "renameFile", "deleteFile":
        io.async {
          let answer = self.answer { try self.dispatch(call.method, args) }
          DispatchQueue.main.async { result(answer) }
        }
      default: result(FlutterMethodNotImplemented)
      }
    } catch { result(flutterError(error)) }
  }

  private func answer(_ body: () throws -> Any?) -> Any? {
    do { return try body() } catch { return flutterError(error) }
  }

  private func flutterError(_ error: Error) -> FlutterError {
    if let failure = error as? Failure {
      return FlutterError(code: failure.code, message: failure.message, details: failure.details)
    }
    let native = error as NSError
    let code: String
    if native.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(native.code) {
      code = "missing"
    } else if native.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(native.code) {
      code = "permission"
    } else { code = "io" }
    // Do not expose native userInfo, which can contain source-private paths/bookmarks.
    return FlutterError(code: code, message: "Native file operation failed", details: ["domain": native.domain, "nativeCode": native.code])
  }

  private func pick(directory: Bool, result: @escaping FlutterResult) throws {
    guard pickerResult == nil else { throw Failure(code: "io", message: "A picker is already open") }
    pickerResult = result; pickingDirectory = directory
    #if os(macOS)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
    panel.allowsMultipleSelection = !directory; panel.canCreateDirectories = directory
    if !directory { panel.allowedFileTypes = ["txt", "md"] }
    panel.begin { response in self.selected(response == .OK ? panel.urls : nil) }
    #else
    let types: [UTType] = directory ? [.folder] : [.plainText, UTType(filenameExtension: "md") ?? .text]
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
    picker.allowsMultipleSelection = !directory; picker.delegate = self
    var controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    guard let controller = controller else {
      pickerResult = nil; throw Failure(code: "io", message: "No active window for document picker")
    }
    controller.present(picker, animated: true)
    #endif
  }

  fileprivate func selected(_ urls: [URL]?) {
    guard let result = pickerResult else { return }
    let directory = pickingDirectory; pickerResult = nil
    guard let urls = urls else { result(nil); return }
    io.async {
      let answer = self.answer {
        guard !urls.isEmpty, !directory || urls.count == 1 else { throw self.missing("Picker returned no selection") }
        var files: [Map] = []
        for url in urls {
          let started = url.startAccessingSecurityScopedResource()
          defer { if started { url.stopAccessingSecurityScopedResource() } }
          let bookmark = try self.bookmark(url)
          // Prove the serialized authorization resolves and can be scoped before returning it.
          let receipt: Map = ["kind": "apple", "locator": url.absoluteString, "authorization": bookmark]
          let scope = try self.scope(receipt)
          defer { scope.close() }
          if directory {
            return try self.inspectRoot(receipt, writable: true)
          }
          let file = try self.coordinateRead(scope.url) { actual -> Map in
            var file = try self.fileMap(actual, root: nil)
            try self.regular(actual)
            guard ["txt", "md"].contains(actual.pathExtension.lowercased()) else {
              throw Failure(code: "unsupported", message: "Select TXT or Markdown files")
            }
            file["authorization"] = scope.authorization
            return file
          }
          files.append(file)
        }
        return files
      }
      DispatchQueue.main.async { result(answer) }
    }
  }

  private func bookmark(_ url: URL) throws -> String {
    #if os(macOS)
    let options: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
    let options: URL.BookmarkCreationOptions = []
    #endif
    return try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil).base64EncodedString()
  }

  private func scope(_ value: Map) throws -> Scope {
    guard let encoded = value["authorization"] as? String, let data = Data(base64Encoded: encoded) else {
      throw Failure(code: "permission", message: "Select the original file or directory to authorize access")
    }
    #if os(macOS)
    let options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
    #else
    let options: URL.BookmarkResolutionOptions = [.withoutUI]
    #endif
    var stale = false
    let url: URL
    do { url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale) }
    catch { throw Failure(code: "permission", message: "Bookmark cannot be resolved; select the resource again") }
    guard url.isFileURL else { throw Failure(code: "unsupported", message: "Bookmark is not a file URL") }
    let started = url.startAccessingSecurityScopedResource()
    guard started || insideSandbox(url) else {
      throw Failure(code: "permission", message: "Security scope is unavailable; select the resource again")
    }
    do {
      let refreshed = stale ? try bookmark(url) : encoded
      return Scope(url: url, started: started, authorization: refreshed)
    } catch { if started { url.stopAccessingSecurityScopedResource() }; throw error }
  }

  private func rootScope(_ root: Map) throws -> Scope {
    guard try string(root, "kind") == "apple" else { throw Failure(code: "unsupported", message: "Expected an Apple root") }
    let access = try scope(root)
    do {
      let info = try metadata(access.url)
      guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw Failure(code: "io", message: "Root is not a directory") }
      return access
    } catch { access.close(); throw error }
  }

  private func withFile<T>(_ file: Map, root: Map?, _ body: (URL, URL?) throws -> T) throws -> T {
    if let root = root {
      let access = try rootScope(root); defer { access.close() }
      let url = try rootedFile(file, root: access.url)
      return try body(url, access.url)
    }
    if file["authorization"] is String {
      let access = try scope(file); defer { access.close() }
      return try body(access.url, nil)
    }
    // Legacy sources are supported only when their actual file URL is inside this app's sandbox.
    let url = try fileURL(string(file, "locator"))
    guard insideSandbox(url) else { throw Failure(code: "permission", message: "External file requires selection and authorization") }
    return try body(url, nil)
  }

  private func dispatch(_ method: String, _ args: Map) throws -> Any? {
    switch method {
    case "inspectRoot": return try inspectRoot(map(args["root"], "root"), writable: boolean(args, "writable"))
    case "list":
      let root = try map(args["root"], "root")
      let access = try rootScope(root); defer { access.close() }
      let directory = try optionalMap(args["directory"], "directory").map { try rootedFile($0, root: access.url) } ?? access.url
      return try coordinateRead(directory) { url in
        let values = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        return try values.map { try fileMap($0, root: access.url, rootMap: root) }
      }
    case "stat", "fingerprint":
      let file = try map(args["file"], "file")
      do {
        return try withFile(file, root: optionalRoot(args, file)) { url, rootURL in
          try coordinateRead(url) { actual -> Any in
            if method == "fingerprint" { try regular(actual); return try fingerprint(actual) }
            return try fileMap(actual, root: rootURL, rootMap: optionalRoot(args, file), authorization: file["authorization"] as? String)
          }
        }
      } catch let failure as Failure where failure.code == "missing" && method == "stat" { return nil }
      catch {
        let native = error as NSError
        if method == "stat" && native.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(native.code) { return nil }
        throw error
      }
    case "fileInRoot":
      let root = try map(args["root"], "root")
      let access = try rootScope(root); defer { access.close() }
      let file = try map(args["file"], "file")
      return try withFile(file, root: optionalMap(file["root"], "file.root")) { url, _ in
        try coordinateRead(url) { actual in
          guard contains(access.url, actual), actual.resolvingSymlinksInPath() != access.url.resolvingSymlinksInPath() else { return nil as Map? }
          return try fileMap(actual, root: access.url, rootMap: root)
        }
      }
    case "deleteFile":
      let root = try map(args["root"], "root")
      return try withFile(map(args["file"], "file"), root: root) { url, _ in
        try coordinateWrite(url, options: .forDeleting) { actual in
          try regular(actual)
          if Darwin.unlink(actual.path) != 0 { throw posix("Delete failed") }
        }
        return nil as Any?
      }
    case "renameFile": return try rename(args)
    default: throw Failure(code: "unsupported", message: "Unknown operation")
    }
  }

  private func inspectRoot(_ root: Map, writable: Bool) throws -> Map {
    let access = try rootScope(root); defer { access.close() }
    return try coordinateWrite(access.url) { url in
      _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
      if writable {
        let probe = url.appendingPathComponent(".liber-probe-" + UUID().uuidString)
        let fd = Darwin.open(probe.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw posix("Directory is not writable") }
        var operationError: Error?
        do {
          var byte: UInt8 = 0x4c
          guard Darwin.write(fd, &byte, 1) == 1, fsync(fd) == 0, lseek(fd, 0, SEEK_SET) == 0 else { throw posix("Write probe failed") }
          byte = 0
          guard Darwin.read(fd, &byte, 1) == 1, byte == 0x4c else { throw Failure(code: "verification", message: "Write probe did not round-trip") }
        } catch { operationError = error }
        if Darwin.close(fd) != 0 && operationError == nil { operationError = posix("Write probe close failed") }
        try cleanup(probe, original: operationError)
        if let error = operationError { throw error }
      }
      return try rootMap(url, authorization: access.authorization)
    }
  }

  private func rootMap(_ url: URL, authorization: String?) throws -> Map {
    let info = try metadata(url)
    return ["kind": "apple", "locator": url.absoluteString, "authorization": authorization.map { $0 as Any } ?? NSNull(),
      "identity": identity(info), "displayName": url.lastPathComponent]
  }

  private func fileMap(_ url: URL, root: URL?, rootMap: Map? = nil, authorization: String? = nil) throws -> Map {
    let actual = url.standardizedFileURL
    let info = try metadata(actual)
    let directory = info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    let key: String
    if let root = root {
      guard contains(root, actual) else { throw Failure(code: "permission", message: "File is outside the selected root") }
      key = actual.resolvingSymlinksInPath().pathComponents.dropFirst(root.resolvingSymlinksInPath().pathComponents.count).joined(separator: "/")
    } else { key = actual.lastPathComponent }
    var file: Map = ["locator": actual.absoluteString, "key": key, "name": actual.lastPathComponent,
      "directory": directory, "size": directory ? NSNull() : NSNumber(value: info.st_size), "identity": identity(info),
      "modifiedAt": info.st_mtimespec.tv_sec > 0 ? NSNumber(value: Int64(info.st_mtimespec.tv_sec) * 1000 + Int64(info.st_mtimespec.tv_nsec) / 1_000_000) : NSNull()]
    if let rootMap = rootMap { file["root"] = rootMap }
    if let authorization = authorization { file["authorization"] = authorization }
    return file
  }

  private func acquireRead(_ args: Map, result: @escaping FlutterResult) throws {
    let file = try map(args["file"], "file")
    let root = try optionalRoot(args, file)
    let token = UUID().uuidString
    let lease = ReadLease()
    leases[token] = lease
    // Each lease needs its own worker; a serial IO queue would deadlock concurrent consumers.
    DispatchQueue.global(qos: .userInitiated).async {
      var delivered = false
      do {
        try self.withFile(file, root: root) { url, rootURL in
          try self.coordinateRead(url) { actual in
            try self.regular(actual)
            let fd = try self.openRead(actual)
            defer { Darwin.close(fd) }
            let metadata = try self.fileMap(actual, root: rootURL, rootMap: root, authorization: file["authorization"] as? String)
            delivered = true
            DispatchQueue.main.async { result(["token": token, "path": actual.path, "file": metadata]) }
            // NSFileCoordinator and the security scope enclose the entire asynchronous Rust read.
            lease.released.wait()
          }
        }
        DispatchQueue.main.async {
          self.leases.removeValue(forKey: token)
          lease.releaseResult?(nil)
        }
      } catch {
        let failure = self.flutterError(error)
        let wasDelivered = delivered
        DispatchQueue.main.async {
          self.leases.removeValue(forKey: token)
          if wasDelivered { lease.releaseResult?(failure) } else { result(failure) }
        }
      }
    }
  }

  private func copy(_ args: Map, job: CopyJob) throws -> Map {
    let source = try map(args["source"], "source")
    let root = try map(args["destinationRoot"], "destinationRoot")
    let name = try name(args, "name")
    let access = try rootScope(root); defer { access.close() }
    return try withFile(source, root: optionalMap(source["root"], "source.root")) { sourceURL, _ in
      try coordinateReadWrite(sourceURL, access.url) { actualSource, actualRoot in
        let destination = actualRoot.appendingPathComponent(name)
        let receipt = try streamCopy(actualSource, destination: destination, job: job)
        do {
          let file = try fileMap(destination, root: actualRoot, rootMap: root)
          return ["file": file, "bytesCopied": receipt["bytes"]!, "sha256": receipt["sha256"]!, "verified": true]
        } catch { try cleanup(destination, original: error); throw error }
      }
    }
  }

  /// O_EXCL creates the only path this operation may clean up. All byte buffers are bounded.
  private func streamCopy(_ source: URL, destination: URL, job: CopyJob) throws -> Map {
    try regular(source)
    let input = try openRead(source); defer { Darwin.close(input) }
    var before = stat()
    guard fstat(input, &before) == 0 else { throw posix("Source metadata failed") }
    job.setTotal(Int64(before.st_size)); try job.check()
    let output = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard output >= 0 else { throw posix("Exclusive destination creation failed") }
    var outputOpen = true
    do {
      var digest = SHA256()
      var count: Int64 = 0
      var buffer = [UInt8](repeating: 0, count: 64 * 1024)
      while true {
        try job.check()
        let length = Darwin.read(input, &buffer, buffer.count)
        if length < 0 { if errno == EINTR { continue }; throw posix("Source read failed") }
        if length == 0 { break }
        try buffer.withUnsafeBytes { raw in
          var offset = 0
          while offset < length {
            try job.check()
            let written = Darwin.write(output, raw.baseAddress!.advanced(by: offset), length - offset)
            if written < 0 { if errno == EINTR { continue }; throw posix("Destination write failed") }
            if written == 0 { throw Failure(code: "io", message: "Destination write made no progress") }
            offset += written
          }
          digest.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: length))
        }
        count += Int64(length); job.advance(length)
      }
      guard fsync(output) == 0 else { throw posix("Destination sync failed") }
      let closeResult = Darwin.close(output); outputOpen = false
      guard closeResult == 0 else { throw posix("Destination close failed") }
      var after = stat()
      guard fstat(input, &after) == 0 else { throw posix("Source metadata failed") }
      guard before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
        before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, count == Int64(before.st_size) else {
        throw Failure(code: "verification", message: "Source changed during copy")
      }
      let hash = hex(digest.finalize())
      let verified = try fingerprint(destination, job: job)
      guard verified["bytes"] as? Int64 == count, verified["sha256"] as? String == hash else {
        throw Failure(code: "verification", message: "Copied bytes did not verify")
      }
      try job.check()
      return ["bytes": count, "sha256": hash]
    } catch {
      if outputOpen { Darwin.close(output) }
      try cleanup(destination, original: error)
      throw error
    }
  }

  private func fingerprint(_ url: URL, job: CopyJob? = nil) throws -> Map {
    let fd = try openRead(url); defer { Darwin.close(fd) }
    var digest = SHA256()
    var count: Int64 = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
      try job?.check()
      let length = Darwin.read(fd, &buffer, buffer.count)
      if length < 0 { if errno == EINTR { continue }; throw posix("Fingerprint read failed") }
      if length == 0 { break }
      buffer.withUnsafeBytes { raw in digest.update(bufferPointer: UnsafeRawBufferPointer(start: raw.baseAddress, count: length)) }
      count += Int64(length)
    }
    return ["bytes": count, "sha256": hex(digest.finalize())]
  }

  private func rename(_ args: Map) throws -> Map {
    let root = try map(args["root"], "root")
    let access = try rootScope(root); defer { access.close() }
    let source = try rootedFile(map(args["file"], "file"), root: access.url)
    let destination = source.deletingLastPathComponent().appendingPathComponent(try name(args, "name"))
    try requireLocalMutation(source)
    return try coordinateWritePair(source, destination) { actualSource, actualDestination in
      try regular(actualSource)
      guard renameatx_np(AT_FDCWD, actualSource.path, AT_FDCWD, actualDestination.path, UInt32(RENAME_EXCL)) == 0 else {
        throw posix("No-clobber rename failed")
      }
      do { return try fileMap(actualDestination, root: access.url, rootMap: root) }
      catch { throw Failure(code: "io", message: "Renamed file metadata failed", details: ["locator": actualDestination.absoluteString]) }
    }
  }

  private func replace(_ args: Map, job: CopyJob) throws -> Map {
    let root = try map(args["root"], "root")
    let access = try rootScope(root); defer { access.close() }
    let staged = try rootedFile(map(args["staged"], "staged"), root: access.url)
    let existing = try rootedFile(map(args["existing"], "existing"), root: access.url)
    let backup = existing.deletingLastPathComponent().appendingPathComponent(try name(args, "backupName"))
    try requireLocalMutation(existing); try requireLocalMutation(staged)
    return try coordinateWritePair(staged, existing) { actualStaged, actualExisting in
      try regular(actualStaged); try regular(actualExisting)
      let old = try metadata(actualExisting), new = try metadata(actualStaged)
      guard old.st_dev == new.st_dev, identity(old) != identity(new), backup != actualStaged, backup != actualExisting else {
        throw Failure(code: "unsupported", message: "Replacement needs distinct ordinary files on one local volume")
      }
      _ = try streamCopy(actualExisting, destination: backup, job: job)
      // Keep this exact backup on every subsequent failure: the controller recorded its name.
      var replaced = false
      do {
        // Persist the recovery name before committing a replacement, not just the backup's bytes.
        let backupDirectory = Darwin.open(backup.deletingLastPathComponent().path, O_RDONLY)
        guard backupDirectory >= 0 else { throw posix("Backup directory open failed") }
        let backupSync = fsync(backupDirectory); Darwin.close(backupDirectory)
        guard backupSync == 0 else { throw posix("Backup directory sync failed") }
        let previous = try fileMap(backup, root: access.url, rootMap: root)
        try job.check()
        guard Darwin.rename(actualStaged.path, actualExisting.path) == 0 else { throw posix("Atomic replacement failed") }
        replaced = true
        let directoryFD = Darwin.open(actualExisting.deletingLastPathComponent().path, O_RDONLY)
        guard directoryFD >= 0 else { throw posix("Replacement directory open failed") }
        let syncResult = fsync(directoryFD); Darwin.close(directoryFD)
        guard syncResult == 0 else { throw posix("Replacement directory sync failed") }
        return ["file": try fileMap(actualExisting, root: access.url, rootMap: root), "previous": previous]
      } catch {
        if replaced {
          // Restore exact previous bytes on an ordinary post-rename failure. A crash before this
          // point still has the verified backup at the controller's pre-recorded unique name.
          if Darwin.rename(backup.path, actualExisting.path) != 0 {
            throw Failure(code: "io", message: "Replacement rollback failed; previous bytes remain at the backup",
              details: ["previousLocator": backup.absoluteString, "existingLocator": actualExisting.absoluteString,
                "rollbackFailed": true, "cause": (error as? Failure)?.code ?? "io"])
          }
          throw Failure(code: "io", message: "Replacement failed; previous bytes restored",
            details: ["previousLocator": actualExisting.absoluteString, "restored": true, "cause": (error as? Failure)?.code ?? "io"])
        }
        throw Failure(code: (error as? Failure)?.code ?? "io", message: "Replacement failed; previous file is unchanged",
          details: ["previousLocator": actualExisting.absoluteString, "backupLocator": backup.absoluteString])
      }
    }
  }

  private func requireLocalMutation(_ url: URL) throws {
    // Local-looking File Provider materializations are not proof of safe POSIX replacement.
    // Only this signed app's own sandbox container is eligible for this optimization.
    guard insideSandbox(url) else {
      throw Failure(code: "unsupported", message: "External providers do not guarantee safe rename or replacement")
    }
    let values = try url.resourceValues(forKeys: [.volumeIsLocalKey, .isUbiquitousItemKey])
    guard values.volumeIsLocal == true, values.isUbiquitousItem != true else {
      throw Failure(code: "unsupported", message: "Replacement requires an ordinary local file")
    }
  }

  private func insideSandbox(_ url: URL) -> Bool {
    #if os(macOS)
    var code: SecCode?
    var staticCode: SecStaticCode?
    var information: CFDictionary?
    guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code = code,
      SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode = staticCode,
      SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
      let info = information as? [String: Any], let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      entitlements["com.apple.security.app-sandbox"] as? Bool == true else { return false }
    #endif
    return contains(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true), url)
      || contains(FileManager.default.temporaryDirectory, url)
  }

  private func coordinateRead<T>(_ url: URL, _ body: (URL) throws -> T) throws -> T {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var outcome: Result<T, Error>?
    coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError) { actual in outcome = Result { try body(actual) } }
    if let error = coordinationError { throw error }
    guard let outcome = outcome else { throw Failure(code: "io", message: "Read coordination did not run") }
    return try outcome.get()
  }

  private func coordinateWrite<T>(_ url: URL, options: NSFileCoordinator.WritingOptions = [], _ body: (URL) throws -> T) throws -> T {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var outcome: Result<T, Error>?
    coordinator.coordinate(writingItemAt: url, options: options, error: &coordinationError) { actual in outcome = Result { try body(actual) } }
    if let error = coordinationError { throw error }
    guard let outcome = outcome else { throw Failure(code: "io", message: "Write coordination did not run") }
    return try outcome.get()
  }

  private func coordinateReadWrite<T>(_ source: URL, _ destination: URL, _ body: (URL, URL) throws -> T) throws -> T {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var outcome: Result<T, Error>?
    coordinator.coordinate(readingItemAt: source, options: [], writingItemAt: destination, options: [], error: &coordinationError) {
      first, second in outcome = Result { try body(first, second) }
    }
    if let error = coordinationError { throw error }
    guard let outcome = outcome else { throw Failure(code: "io", message: "Copy coordination did not run") }
    return try outcome.get()
  }

  private func coordinateWritePair<T>(_ first: URL, _ second: URL, _ body: (URL, URL) throws -> T) throws -> T {
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var coordinationError: NSError?
    var outcome: Result<T, Error>?
    coordinator.coordinate(writingItemAt: first, options: .forMoving, writingItemAt: second, options: .forReplacing, error: &coordinationError) {
      a, b in outcome = Result { try body(a, b) }
    }
    if let error = coordinationError { throw error }
    guard let outcome = outcome else { throw Failure(code: "io", message: "Replacement coordination did not run") }
    return try outcome.get()
  }

  private func metadata(_ url: URL) throws -> stat {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { throw posix("File metadata unavailable") }
    guard info.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK) else { throw Failure(code: "unsupported", message: "Symbolic links are not library documents") }
    return info
  }
  private func regular(_ url: URL) throws {
    guard try metadata(url).st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure(code: "unsupported", message: "Expected an ordinary file") }
  }
  private func openRead(_ url: URL) throws -> Int32 {
    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard fd >= 0 else { throw posix("File open failed") }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), lseek(fd, 0, SEEK_SET) == 0 else {
      Darwin.close(fd); throw Failure(code: "unsupported", message: "File is not regular and seekable")
    }
    return fd
  }
  private func cleanup(_ url: URL, original: Error?) throws {
    if Darwin.unlink(url.path) != 0 {
      throw Failure(code: "io", message: "Owned temporary file cleanup failed", details: ["cleanupFailed": true,
        "locator": url.absoluteString, "cause": (original as? Failure)?.code ?? "io"])
    }
  }
  private func posix(_ message: String) -> Failure {
    let code = errno
    let kind: String
    switch code {
    case EACCES, EPERM: kind = "permission"
    case ENOENT: kind = "missing"
    case EEXIST: kind = "collision"
    case ENOTSUP, EXDEV: kind = "unsupported"
    default: kind = "io"
    }
    return Failure(code: kind, message: message, details: ["errno": code])
  }
  private func rootedFile(_ file: Map, root: URL) throws -> URL {
    // A selected source's basename is not a rooted key. fileInRoot must first prove its
    // membership and return a rooted receipt without the independent source authorization.
    if let authorization = file["authorization"], !(authorization is NSNull) {
      throw Failure(code: "permission", message: "Selected source requires a canonical rooted receipt")
    }
    guard let receiptRoot = try optionalMap(file["root"], "file.root") else {
      throw Failure(code: "permission", message: "File requires a canonical rooted receipt")
    }
    guard try string(receiptRoot, "kind") == "apple" else {
      throw Failure(code: "permission", message: "File receipt belongs to a different root")
    }
    // Identity strings are metadata, not authorization. Resolve both bookmarks' actual roots
    // even when their claimed identities match; a renewed bookmark may still follow the same root.
    let receiptAccess = try rootScope(receiptRoot); defer { receiptAccess.close() }
    guard identity(try metadata(receiptAccess.url)) == identity(try metadata(root)) else {
      throw Failure(code: "permission", message: "File receipt belongs to a different root")
    }
    guard let key = file["key"] as? String else { throw Failure(code: "io", message: "Invalid file key") }
    let components = key.components(separatedBy: "/")
    guard !key.contains("\0"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw Failure(code: "permission", message: "File key must be a relative path without traversal or empty components")
    }
    // The authorized root bookmark can move while a persisted child's absolute locator stays old.
    let url = root.appendingPathComponent(key).standardizedFileURL
    guard contains(root, url), url.resolvingSymlinksInPath() != root.resolvingSymlinksInPath() else {
      throw Failure(code: "permission", message: "File is outside the selected root")
    }
    return url
  }
  private func contains(_ root: URL, _ file: URL) -> Bool {
    let parent = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let child = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    return child.starts(with: parent)
  }
  private func fileURL(_ value: String) throws -> URL {
    guard let url = URL(string: value), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
      throw Failure(code: "unsupported", message: "Expected an original file URL")
    }
    return url.standardizedFileURL
  }
  private func optionalMap(_ value: Any?, _ field: String) throws -> Map? {
    if value == nil || value is NSNull { return nil }
    return try map(value, field)
  }
  private func optionalRoot(_ args: Map, _ file: Map) throws -> Map? {
    return try optionalMap((args["root"] is NSNull ? nil : args["root"]) ?? file["root"], "root")
  }
  private func identity(_ info: stat) -> String { "\(info.st_dev):\(info.st_ino)" }
  private func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
  private func missing(_ message: String) -> Failure { Failure(code: "missing", message: message) }
  private func map(_ value: Any?, _ field: String) throws -> Map {
    guard let value = value as? Map else { throw Failure(code: "io", message: "Invalid \(field) map") }; return value
  }
  private func string(_ args: Map, _ field: String) throws -> String {
    guard let value = args[field] as? String, !value.isEmpty else { throw Failure(code: "io", message: "Invalid \(field)") }; return value
  }
  private func boolean(_ args: Map, _ field: String) throws -> Bool {
    guard let value = args[field] as? Bool else { throw Failure(code: "io", message: "Invalid \(field)") }; return value
  }
  private func name(_ args: Map, _ field: String) throws -> String {
    let value = try string(args, field)
    guard value != ".", value != "..", !value.contains("/"), !value.contains("\\"), !value.contains("\0") else {
      throw Failure(code: "io", message: "Invalid file name")
    }
    return value
  }
}

#if os(iOS)
extension LocalLibraryChannel: UIDocumentPickerDelegate {
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { selected(urls) }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { selected(nil) }
}
#endif
