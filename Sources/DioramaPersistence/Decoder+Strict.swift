public extension Decoder {
    /// Returns a keyed container after rejecting fields outside the declared keys.
    ///
    /// - Parameter type: The complete set of accepted coding keys.
    /// - Throws: ``PersistedScenarioCodingError/unknownField(codingPath:field:)``
    ///   when the container includes an undeclared field.
    func strictContainer<Key: CodingKey & CaseIterable>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        try rejectUnknownKeys(type)
        return try container(keyedBy: type)
    }
}

private extension Decoder {
    func rejectUnknownKeys<Key: CodingKey & CaseIterable>(_: Key.Type) throws {
        let container = try container(keyedBy: AnyCodingKey.self)
        let allowedKeys = Set(Key.allCases.map(\.stringValue))

        guard let unknownKey = container.allKeys
            .map(\.stringValue)
            .sorted()
            .first(where: { !allowedKeys.contains($0) })
        else {
            return
        }

        throw PersistedScenarioCodingError.unknownField(
            codingPath: persistedCodingPath(codingPath),
            field: unknownKey)
    }
}

func persistedCodingPath(_ codingPath: [any CodingKey]) -> [String] {
    codingPath.map { key in
        if let index = key.intValue {
            String(index)
        } else {
            key.stringValue
        }
    }
}

private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
