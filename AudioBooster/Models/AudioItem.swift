import Foundation

struct AudioItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var urlString: String
    var dateAdded: Date = Date()
    var lastBoostMultiplier: Float = 1.0

    var url: URL? {
        URL(string: urlString)
    }
}
