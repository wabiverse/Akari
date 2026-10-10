import Foundation

public enum Kraken
{
  public struct SceneFile
  {
    public var fileURL: URL
    public var name: String
    
    public init(fileURL: URL)
    {
      self.fileURL = fileURL
      self.name = fileURL.pathComponents.suffix(2).joined(separator: "/")
    }
  }
}
