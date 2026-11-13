import DioramaCore
import DioramaHTTP
@testable import DioramaPersistence
import Foundation

enum HTTPResourceCodingFixtures {
    static func resource(path: String, bytes: [UInt8] = [0, 255]) throws -> HTTPBodyResource {
        try HTTPBodyResource(path: path, bytes: ValuePreparation<[UInt8]>().admitPrepared(bytes))
    }

    static func decoder(resources: [String: [UInt8]]) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[resourceCodingKey] = ScenarioDocumentSnapshot(data: Data()) { path in
            guard let bytes = resources[path.value] else { throw ScenarioResourceError.unavailable }
            return Data(bytes)
        }
        return decoder
    }
}
