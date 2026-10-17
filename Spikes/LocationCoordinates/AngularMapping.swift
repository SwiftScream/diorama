/// Experimental degree offsets and pole reflection; no production imports.
enum AngularMapping {
    typealias Coordinate = Mapping.Coordinate

    struct Offset: Equatable {
        let latitude: Double
        let longitude: Double
    }

    static func forward(origin: Coordinate, point: Coordinate) throws -> Offset {
        guard origin.valid, point.valid else { throw Mapping.Failure.coordinate }
        let origin = origin.canonical
        let point = point.canonical
        // All longitude aliases of a pole represent the same recorded point.
        // Use the origin's reference meridian for that point's angular offset.
        return Offset(
            latitude: cleanZero(point.latitude - origin.latitude),
            longitude: abs(point.latitude) == 90 ? 0 : Mapping.wrapDegrees(point.longitude - origin.longitude))
    }

    static func inverse(origin: Coordinate, offset: Offset) throws -> Coordinate {
        guard origin.valid else { throw Mapping.Failure.coordinate }
        let origin = origin.canonical
        guard offset.latitude.isFinite, offset.longitude.isFinite,
              abs(offset.latitude) <= 180, abs(offset.longitude) <= 180
        else { throw Mapping.Failure.offset }
        // Valid origins and bounded angular offsets keep the raw latitude in
        // [-270, 270]. One reflection handles either pole and the opposite pole.
        var latitude = origin.latitude + offset.latitude
        var longitude = origin.longitude + Mapping.wrapDegrees(offset.longitude)
        if latitude > 90 {
            latitude = 180 - latitude
            longitude += 180
        } else if latitude < -90 {
            latitude = -180 - latitude
            longitude += 180
        }
        return Coordinate(latitude: cleanZero(latitude), longitude: Mapping.wrapDegrees(longitude))
    }

    private static func cleanZero(_ value: Double) -> Double {
        value == 0 ? 0 : value
    }
}
