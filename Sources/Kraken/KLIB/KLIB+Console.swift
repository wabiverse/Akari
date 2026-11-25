/* -----------------------------------------------------------------
 * :: :  A  K  A  R  I  :                                         ::
 * -----------------------------------------------------------------
 * Redistribution  and  use  in  source  and  binary  forms, with or
 * without  modification,  are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions  in  binary  form  must  reproduce  the  above
 *    copyright  notice,  this  list of conditions and the following
 *    disclaimer   in   the  documentation  and/or  other  materials
 *    provided with the distribution.
 *
 * 3. Neither the name of  the copyright holder nor the names of its
 *    contributors  may  be  used  to  endorse  or  promote products
 *    derived  from  this  software  without  specific prior written
 *    permission.
 *
 * THIS   SOFTWARE   IS   PROVIDED  BY  THE  COPYRIGHT  HOLDERS  AND
 * CONTRIBUTORS  "AS  IS"  AND  ANY  EXPRESS  OR IMPLIED WARRANTIES,
 * INCLUDING,   BUT  NOT  LIMITED  TO,  THE  IMPLIED  WARRANTIES  OF
 * MERCHANTABILITY   AND   FITNESS  FOR  A  PARTICULAR  PURPOSE  ARE
 * DISCLAIMED.   IN   NO   EVENT   SHALL  THE  COPYRIGHT  HOLDER  OR
 * CONTRIBUTORS  BE  LIABLE  FOR  ANY  DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL,  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED  TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
 * USE,  DATA,  OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
 * AND  ON  ANY  THEORY  OF  LIABILITY,  WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY  WAY  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 *                               Copyright (C) 2026 Wabi Foundation.
 *                                              All rights reserved.
 * -----------------------------------------------------------------
 *  . x x x . o o o . x x x . : : : .    o  x  o    . : : : .
 * ----------------------------------------------------------------- */

import Foundation

/// kraken terminal output, colored in a terminal and plain in pipes, logs or with no color set
public enum Console
{
  /// who a line is from
  public enum Source: String
  {
    case kraken, akari, lattice

    var color: Style
    {
      switch self
      {
        case .kraken: .magenta
        case .akari: .cyan
        case .lattice: .blue
      }
    }
  }

  public enum Style: String
  {
    case bold = "1", dim = "2", red = "31", green = "32", yellow = "33", blue = "34", magenta = "35", cyan = "36", gray = "90"
  }

  /// a relaunched background render writes through a pipe, so its parent passes the terminals colors on
  public static let colors: Bool =
  {
    let env = ProcessInfo.processInfo.environment
    guard env["NO_COLOR"] == nil, env["TERM"] != "dumb" else { return false }
    return env["AKARI_COLOR"] == "1" || isatty(STDOUT_FILENO) != 0
  }()

  /// text in styles when colors are on
  public static func paint(_ text: String, _ styles: Style...) -> String
  {
    guard colors, !styles.isEmpty else { return text }
    return "\u{1B}[\(styles.map(\.rawValue).joined(separator: ";"))m\(text)\u{1B}[0m"
  }

  private static func tag(_ source: Source) -> String
  {
    colors ? paint(source.rawValue, .bold, source.color) : "[\(source.rawValue)]"
  }

  private static func write(_ line: String, error: Bool = false)
  {
    (error ? FileHandle.standardError : FileHandle.standardOutput).write(Data((line + "\n").utf8))
  }

  public static func info(_ message: String, from source: Source = .kraken)
  {
    write("\(tag(source)) \(message)")
  }

  public static func success(_ message: String, from source: Source = .kraken)
  {
    write("\(tag(source)) \(paint("✓", .bold, .green)) \(message)")
  }

  public static func warn(_ message: String, from source: Source = .kraken)
  {
    write("\(tag(source)) \(paint("warning:", .bold, .yellow)) \(message)", error: true)
  }

  public static func error(_ message: String, from source: Source = .kraken)
  {
    write("\(tag(source)) \(paint("error:", .bold, .red)) \(message)", error: true)
  }

  /// a quiet detail line
  public static func detail(_ message: String, from source: Source = .kraken)
  {
    write("\(tag(source)) \(paint(message, .dim))")
  }

  /// the usage with its headings and flags picked out
  public static func usage(_ text: String)
  {
    guard colors else { return write(text) }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map
    { raw -> String in
      let line = String(raw)
      if line.hasPrefix("usage:") { return paint("usage:", .bold) + String(line.dropFirst(6)) }

      // headings sit flush left
      if !line.isEmpty, !line.hasPrefix(" ") { return paint(line, .bold, .magenta) }

      // a flag column then its description
      guard let split = line.range(of: "  ", options: [], range: line.index(line.startIndex, offsetBy: min(4, line.count)) ..< line.endIndex)
      else { return line }
      let flags = String(line[..<split.lowerBound]), rest = String(line[split.lowerBound...])
      return paint(flags, .cyan) + paint(rest, .dim)
    }

    write(lines.joined(separator: "\n"))
  }
}
