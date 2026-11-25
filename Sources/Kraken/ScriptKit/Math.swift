import Foundation

/// a point or direction in meters
public typealias Vec3 = SIMD3<Double>

public extension SIMD3 where Scalar == Double
{
  static let up = Vec3(0, 0, 1)
  static let down = Vec3(0, 0, -1)
  static let right = Vec3(1, 0, 0)
  static let left = Vec3(-1, 0, 0)
  static let forward = Vec3(0, 1, 0)
  static let back = Vec3(0, -1, 0)

  var length: Double { (self * self).sum().squareRoot() }
  var normalized: Vec3 { length > 0 ? self / length : self }
  func dot(_ other: Vec3) -> Double { (self * other).sum() }
  func cross(_ o: Vec3) -> Vec3 { Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x) }
  func distance(to other: Vec3) -> Double { (self - other).length }

  /// distance from the z axis
  var radial: Double { (x * x + y * y).squareRoot() }

  /// degrees around z from x
  var azimuth: Double
  {
    let a = atan2(y, x) * 180 / .pi
    return a < 0 ? a + 360 : a
  }
}

public enum Axis: String, Sendable
{
  case x, y, z

  public var vector: Vec3
  {
    switch self
    {
      case .x: .right
      case .y: .forward
      case .z: .up
    }
  }
}

public extension ClosedRange where Bound == Double
{
  /// middle and length
  var middle: Double { (lowerBound + upperBound) / 2 }
  var span: Double { upperBound - lowerBound }
}
