import SwiftUI

/// The app's name, always in capitals.
let brandName = "PULSHADE"

extension Text {
    /// `string`, with each PULSHADE in it set a step smaller, so the capitals sit level with the words around it
    /// instead of shouting over them.
    init(branded string: String) {
        var text = Text(verbatim: "")
        var rest = Substring(string)
        while let range = rest.range(of: brandName) {
            text = Text("\(text)\(Text(verbatim: String(rest[..<range.lowerBound])))\(Text(verbatim: brandName).textScale(.secondary))")
            rest = rest[range.upperBound...]
        }
        self = Text("\(text)\(Text(verbatim: String(rest)))")
    }
}
