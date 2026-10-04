import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
enum FontCatalog {
    static var availableFamilies: [String] {
        #if os(macOS)
        NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        #elseif os(iOS)
        UIFont.familyNames.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        #endif
    }
}
