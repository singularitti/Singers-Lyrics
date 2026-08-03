import Foundation

struct SymbolCategory: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var symbols: [String]
}

enum SymbolCatalog {
    static let categories = [
        SymbolCategory(
            name: "Music",
            symbols: ["♪", "♫", "♬", "♩", "♭", "♮", "♯", "𝄞", "𝄢", "🎵", "🎶", "🎤", "🎧", "🎸", "🎹", "🥁"]
        ),
        SymbolCategory(
            name: "Hearts & Stars",
            symbols: ["♥", "❤", "♡", "☆", "★", "✦", "✧", "✪", "✵", "✹", "✿", "❀", "❉", "❋", "❈", "✴"]
        ),
        SymbolCategory(
            name: "Arrows",
            symbols: ["←", "↑", "→", "↓", "↔", "↕", "↵", "↺", "↻", "⤳", "➜", "➤", "▶", "◀", "▲", "▼"]
        ),
        SymbolCategory(
            name: "Punctuation",
            symbols: ["—", "–", "…", "•", "·", "“", "”", "‘", "’", "«", "»", "†", "‡", "§", "¶", "※"]
        ),
        SymbolCategory(
            name: "Symbols",
            symbols: ["∞", "☀", "☾", "♨", "⚓", "⚖", "⚡", "✈", "✗", "✓", "©", "®", "™", "°", "′", "″"]
        ),
    ]
}
