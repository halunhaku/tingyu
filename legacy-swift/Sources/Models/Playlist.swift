import Foundation
import SwiftData

@Model
public final class Playlist {
    public var id: String = UUID().uuidString
    public var name: String = ""
    public var createdAt: Date = Date()
    public var trackIds: [String] = []
    public init(
        id: String = UUID().uuidString,
        name: String,
        createdAt: Date = Date(),
        trackIds: [String] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.trackIds = trackIds
    }
}
