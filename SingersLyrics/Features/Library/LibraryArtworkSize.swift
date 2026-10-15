#if os(macOS)
import Foundation

enum LibraryArtworkSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: Self { self }

    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    var dimension: CGFloat {
        switch self {
        case .small: 48
        case .medium: 56
        case .large: 96
        }
    }

    var rowVerticalPadding: CGFloat {
        switch self {
        case .small: 8
        case .medium: 11
        case .large: 12
        }
    }
}
#endif
