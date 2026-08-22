import Foundation

/// A parsed XML element: name, attributes and child elements.
///
/// This deliberately tiny parser covers the XML subset SVG files use in
/// practice — elements, attributes, character/entity references, comments,
/// CDATA sections and a skipped prolog/DOCTYPE. It keeps text content
/// (needed for `<style>` and future `<text>` support) but no other node types.
struct SVGXMLElement {
    var name: String
    var attributes: [String: String] = [:]
    var children: [SVGXMLElement] = []
    var text: String = ""

    /// Depth-first search for the first element matching the predicate.
    func first(where predicate: (SVGXMLElement) -> Bool) -> SVGXMLElement? {
        if predicate(self) { return self }
        for child in children {
            if let match = child.first(where: predicate) { return match }
        }
        return nil
    }
}

/// Parses an XML document into an element tree.
struct SVGXMLParser {
    private let scalars: [UnicodeScalar]
    private var position = 0

    init(_ text: String) {
        self.scalars = Array(text.unicodeScalars)
    }

    /// Parses the document and returns its root element.
    static func parse(_ data: Data) throws -> SVGXMLElement {
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw ImageError.invalidData(reason: "SVG is not valid UTF-8 or Latin-1 text")
        }
        var parser = SVGXMLParser(text)
        return try parser.parseDocument()
    }

    // MARK: Scanning primitives

    private var isAtEnd: Bool { position >= scalars.count }

    private func peek(_ offset: Int = 0) -> UnicodeScalar? {
        let index = position + offset
        return index < scalars.count ? scalars[index] : nil
    }

    private mutating func advance() -> UnicodeScalar? {
        guard !isAtEnd else { return nil }
        defer { position += 1 }
        return scalars[position]
    }

    private mutating func skipWhitespace() {
        while let scalar = peek(), scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" {
            position += 1
        }
    }

    private mutating func match(_ literal: String) -> Bool {
        let literalScalars = Array(literal.unicodeScalars)
        guard position + literalScalars.count <= scalars.count else { return false }
        for (offset, scalar) in literalScalars.enumerated() where scalars[position + offset] != scalar {
            return false
        }
        position += literalScalars.count
        return true
    }

    /// Advances past the given literal, or to the end of input if absent.
    private mutating func skip(past literal: String) {
        while !isAtEnd {
            if match(literal) { return }
            position += 1
        }
    }

    // MARK: Document structure

    private mutating func parseDocument() throws -> SVGXMLElement {
        // Skip a UTF-8 BOM if present.
        if peek() == "\u{FEFF}" { position += 1 }
        try skipProlog()
        guard let root = try parseElement() else {
            throw ImageError.invalidData(reason: "SVG contains no root element")
        }
        return root
    }

    /// Skips whitespace, the XML declaration, comments, DOCTYPE and
    /// processing instructions that may precede the root element.
    private mutating func skipProlog() throws {
        while true {
            skipWhitespace()
            if match("<!--") {
                skip(past: "-->")
            } else if match("<?") {
                skip(past: "?>")
            } else if match("<!DOCTYPE") {
                try skipDoctype()
            } else {
                return
            }
        }
    }

    /// DOCTYPE may contain a bracketed internal subset, so `>` alone
    /// isn't a reliable terminator.
    private mutating func skipDoctype() throws {
        var bracketDepth = 0
        while let scalar = advance() {
            if scalar == "[" { bracketDepth += 1 }
            if scalar == "]" { bracketDepth -= 1 }
            if scalar == ">" && bracketDepth <= 0 { return }
        }
        throw ImageError.invalidData(reason: "Unterminated DOCTYPE in SVG")
    }

    // MARK: Elements

    /// Parses one element (with its subtree). Returns nil at a closing tag,
    /// leaving the position on it for the caller to consume.
    private mutating func parseElement() throws -> SVGXMLElement? {
        guard peek() == "<" else {
            throw ImageError.invalidData(reason: "Expected element in SVG")
        }
        if peek(1) == "/" { return nil }
        position += 1  // consume "<"

        var element = SVGXMLElement(name: try parseName())
        try parseAttributes(into: &element)

        skipWhitespace()
        if match("/>") { return element }
        guard match(">") else {
            throw ImageError.invalidData(reason: "Malformed SVG tag \(element.name)")
        }
        try parseContent(into: &element)
        return element
    }

    private mutating func parseName() throws -> String {
        var name = String.UnicodeScalarView()
        while let scalar = peek(), isNameScalar(scalar) {
            name.append(scalar)
            position += 1
        }
        guard !name.isEmpty else {
            throw ImageError.invalidData(reason: "Missing name in SVG tag")
        }
        return String(name)
    }

    private func isNameScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ":", ".":
            return true
        default:
            return scalar.value > 0x7F  // permit non-ASCII names
        }
    }

    private mutating func parseAttributes(into element: inout SVGXMLElement) throws {
        while true {
            skipWhitespace()
            guard let scalar = peek(), isNameScalar(scalar) else { return }
            let name = try parseName()
            skipWhitespace()
            guard match("=") else {
                // Attribute without a value (invalid XML, but tolerated).
                element.attributes[name] = ""
                continue
            }
            skipWhitespace()
            guard let quote = peek(), quote == "\"" || quote == "'" else {
                throw ImageError.invalidData(reason: "Unquoted attribute value in SVG")
            }
            position += 1
            var value = String.UnicodeScalarView()
            while let scalar = peek(), scalar != quote {
                value.append(scalar)
                position += 1
            }
            guard match(String(quote)) else {
                throw ImageError.invalidData(reason: "Unterminated attribute value in SVG")
            }
            element.attributes[name] = Self.decodeEntities(String(value))
        }
    }

    /// Parses children and text until the element's closing tag.
    private mutating func parseContent(into element: inout SVGXMLElement) throws {
        var text = String.UnicodeScalarView()
        while !isAtEnd {
            if peek() == "<" {
                if match("<!--") {
                    skip(past: "-->")
                } else if match("<![CDATA[") {
                    let start = position
                    skip(past: "]]>")
                    let end = max(start, position - 3)
                    text.append(contentsOf: scalars[start..<end])
                } else if match("<?") {
                    skip(past: "?>")
                } else if peek(1) == "/" {
                    position += 2
                    _ = try parseName()
                    skipWhitespace()
                    guard match(">") else {
                        throw ImageError.invalidData(reason: "Malformed closing tag in SVG")
                    }
                    element.text = Self.decodeEntities(String(text))
                    return
                } else if let child = try parseElement() {
                    element.children.append(child)
                }
            } else if let scalar = advance() {
                text.append(scalar)
            }
        }
        throw ImageError.invalidData(reason: "Unclosed SVG element \(element.name)")
    }

    // MARK: Entities

    /// Replaces the predefined XML entities and numeric character references.
    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&" else {
                result.append(scalars[index])
                index += 1
                continue
            }
            // Find the terminating ";" within a reasonable distance.
            var end = index + 1
            while end < scalars.count && end - index <= 10 && scalars[end] != ";" {
                end += 1
            }
            guard end < scalars.count, scalars[end] == ";" else {
                result.append(scalars[index])
                index += 1
                continue
            }
            let name = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
            if let replacement = decodeEntity(name) {
                result.append(replacement)
                index = end + 1
            } else {
                result.append(scalars[index])
                index += 1
            }
        }
        return String(result)
    }

    private static func decodeEntity(_ name: String) -> UnicodeScalar? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits)
            }
            guard let value else { return nil }
            return UnicodeScalar(value)
        }
    }
}
