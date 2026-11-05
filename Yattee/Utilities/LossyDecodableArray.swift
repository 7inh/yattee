//
//  LossyDecodableArray.swift
//  Yattee
//
//  Keeps valid records when upgrading a collection containing retired source types.
//

import Foundation

struct LossyDecodableArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            let entry = try container.superDecoder()
            if let value = try? Element(from: entry) { elements.append(value) }
        }
        self.elements = elements
    }
}

extension LossyDecodableArray: Sendable where Element: Sendable {}
