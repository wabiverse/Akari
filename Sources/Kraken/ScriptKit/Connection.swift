// the kraken script api

@_exported import Foundation

/// what a failed call says
public struct KrakenError: Error, CustomStringConvertible
{
  public var operation: String
  public var message: String

  public var description: String
  {
    "\(operation): \(message)"
  }
}

/// the running kraken
public enum Kraken
{
  /// the scripts own args
  public static var arguments: [String]
  {
    Array(CommandLine.arguments.dropFirst())
  }

  /// this script file
  public static var scriptPath: String
  {
    ProcessInfo.processInfo.environment["KRAKEN_SCRIPT"] ?? CommandLine.arguments[0]
  }

  /// kraken version
  public static var version: String
  {
    (Connection.shared.call("hello") as? [String: Any])?["version"] as? String ?? ""
  }

  /// shows text in the status bar
  public static func status(_ text: String)
  {
    Connection.shared.call("status", ["text": text])
  }

  /// ctrl z and ctrl shift z
  public static func undo()
  {
    Connection.shared.call("undo")
  }

  public static func redo()
  {
    Connection.shared.call("redo")
  }

  /// seconds to wait after each edit to watch it build
  public static var pace: Double
  {
    get { Connection.shared.pace }
    set { Connection.shared.pace = max(newValue, 0) }
  }

  /// sends a raw request
  @discardableResult
  public static func call(_ operation: String, _ arguments: [String: Any] = [:]) throws -> Any
  {
    try Connection.shared.request(operation, arguments)
  }
}

/// talks to kraken over its socket
final class Connection
{
  nonisolated(unsafe) static let shared = Connection()

  private var socket: Int32 = -1
  private var pending = Data()
  private var next = 0
  var pace = Double(ProcessInfo.processInfo.environment["KRAKEN_PACE"] ?? "") ?? 0
  /// reads that never wait
  private static let reads: Set = ["hello", "prims", "get", "attr.get", "materials", "variants", "mesh", "cursor", "stage", "stats"]

  private init()
  {
    guard let path = ProcessInfo.processInfo.environment["KRAKEN_SOCKET"] else
    {
      Self.die("not connected to Kraken, run the script with `Kraken -S script.swift` or File > Run Script…")
    }

    socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes.prefix(raw.count).map { UInt8(bitPattern: $0) })
    }

    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }

    if connected != 0 { Self.die("couldn't reach Kraken at \(path): \(String(cString: strerror(errno)))") }
    if ProcessInfo.processInfo.environment["KRAKEN_FOLLOW"] == "1" { _ = try? request("follow", ["on": true]) }
  }

  static func die(_ message: String) -> Never
  {
    let env = ProcessInfo.processInfo.environment
    let colors = env["NO_COLOR"] == nil && (env["AKARI_COLOR"] == "1" || isatty(STDERR_FILENO) != 0)
    let label = colors ? "\u{1B}[1;35mkraken\u{1B}[0m \u{1B}[1;31merror:\u{1B}[0m" : "[kraken] error:"
    FileHandle.standardError.write(Data("\(label) \(message)\n".utf8))
    exit(1)
  }

  /// a request that ends the script if it fails
  @discardableResult
  func call(_ operation: String, _ arguments: [String: Any] = [:]) -> Any
  {
    do
    {
      return try request(operation, arguments)
    }
    catch
    {
      Self.die("\(error)")
    }
  }

  func request(_ operation: String, _ arguments: [String: Any]) throws -> Any
  {
    next += 1
    let message: [String: Any] = ["id": next, "op": operation, "args": arguments]
    guard JSONSerialization.isValidJSONObject(message) else
    {
      throw KrakenError(operation: operation, message: "arguments aren't JSON: \(arguments)")
    }

    var data = try JSONSerialization.data(withJSONObject: message)
    data.append(0x0A)
    try data.withUnsafeBytes { raw in
      var offset = 0
      while offset < raw.count
      {
        let n = write(socket, raw.baseAddress! + offset, raw.count - offset)
        if n <= 0 { throw KrakenError(operation: operation, message: "Kraken hung up") }
        offset += n
      }
    }

    var chunk = [UInt8](repeating: 0, count: 65536)
    while true
    {
      if let newline = pending.firstIndex(of: 0x0A)
      {
        let line = pending[pending.startIndex ..< newline]
        pending = Data(pending[pending.index(after: newline)...])
        guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else
        {
          throw KrakenError(operation: operation, message: "unreadable reply")
        }

        if reply["ok"] as? Bool == true
        {
          if pace > 0, !Self.reads.contains(operation) { usleep(useconds_t(pace * 1_000_000)) }
          return reply["result"] ?? NSNull()
        }
        throw KrakenError(operation: operation, message: reply["error"] as? String ?? "failed")
      }

      let count = read(socket, &chunk, chunk.count)
      if count <= 0 { throw KrakenError(operation: operation, message: "Kraken hung up") }
      pending.append(chunk, count: count)
    }
  }
}

extension Dictionary where Key == String, Value == Any
{
  func vector(_ key: String) -> Vec3
  {
    let a = (self[key] as? [Any])?.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) } ?? []
    return a.count == 3 ? Vec3(a[0], a[1], a[2]) : .zero
  }
}

func json(_ v: Vec3) -> [Double]
{
  [v.x, v.y, v.z]
}
