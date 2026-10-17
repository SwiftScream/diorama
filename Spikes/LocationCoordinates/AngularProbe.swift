import Foundation

enum AngularProbe {
    typealias Coordinate = Mapping.Coordinate
    typealias Offset = AngularMapping.Offset

    struct Measurements {
        var count = 0
        var maximum = 0.0
        var output = "id,latitude,longitude\n"

        mutating func observe(_ point: Coordinate, expected: Coordinate, label: String) throws {
            try Probe.check(point.valid, "Invalid angular output: \(label)")
            let error = Probe.chord(point, expected)
            try Probe.check(error.isFinite && error <= 0.01, "Angular position error: \(label), \(error) m")
            maximum = max(maximum, error)
            count += 1
            output += "\(label),\(point.latitude),\(point.longitude)\n"
        }
    }

    static func run(outputPath: String) throws {
        var measurements = Measurements()
        let relocated = Coordinate(latitude: 80, longitude: 179.9)
        for latitude in [-90.0, -89.999999, -60, 0, 60, 89.999999, 90] {
            for longitude in [-180.0, -45, 0, 179.999999, 180] {
                let origin = Coordinate(latitude: latitude, longitude: longitude)
                for targetLatitude in [
                    -90.0, -89.999999, -80, -45, -10, -0.000001, 0, 0.000001,
                    10, 45, 80, 89.999999, 90,
                ] {
                    for targetLongitude in [-180.0, -179.999999, -90, 0, 90, 179.999999, 180] {
                        let target = Coordinate(latitude: targetLatitude, longitude: targetLongitude)
                        let offset = try AngularMapping.forward(origin: origin, point: target)
                        let decoded = try AngularMapping.inverse(origin: origin, offset: offset)
                        let label = "angular-\(measurements.count)"
                        try measurements.observe(decoded, expected: target, label: label)
                        let moved = try AngularMapping.inverse(origin: relocated, offset: offset)
                        // Independent trigonometric interpretation of unrestricted
                        // latitude/longitude, without using the reflection branches.
                        let expected = direction(
                            latitude: relocated.latitude + offset.latitude,
                            longitude: relocated.longitude + offset.longitude)
                        try measurements.observe(moved, expected: expected, label: label + "-moved")
                        let restored = try AngularMapping.inverse(origin: origin, offset: offset)
                        try Probe.check(restored == decoded, "Origin edit must retain the stored offset")
                    }
                }
            }
        }
        try checkReflections(measurements: &measurements)
        try checkLoopsAndPoles()
        try checkRelocationLimits()
        let rejections = try checkRejections()
        try measurements.output.write(toFile: outputPath, atomically: true, encoding: .utf8)
        print("PASS: \(measurements.count) angular position checks; \(rejections) rejection checks; "
            + "pole aliases, loops, and retained-offset origin edits")
        print("maximum angular position error: \(measurements.maximum) m")
    }

    static func direction(latitude: Double, longitude: Double) -> Coordinate {
        let latitude = latitude * .pi / 180
        let longitude = longitude * .pi / 180
        let cartesianX = cos(latitude) * cos(longitude)
        let cartesianY = cos(latitude) * sin(longitude)
        return Coordinate(latitude: atan2(sin(latitude), hypot(cartesianX, cartesianY)) * 180 / .pi,
                          longitude: atan2(cartesianY, cartesianX) * 180 / .pi)
    }

    static func checkReflections(measurements: inout Measurements) throws {
        for (originLatitude, deltaLatitude, expectedLatitude, expectedLongitude) in [
            (0.0, 100.0, 80.0, -160.0), (0, -100, -80, -160),
            (80, 10, 90, 20), (80, 20, 80, -160), (-80, -20, -80, -160),
            (90, 180, -90, -160), (-90, -180, 90, -160),
        ] {
            let point = try AngularMapping.inverse(
                origin: Coordinate(latitude: originLatitude, longitude: 20),
                offset: Offset(latitude: deltaLatitude, longitude: 0))
            let expected = Coordinate(latitude: expectedLatitude, longitude: expectedLongitude)
            try Probe.check(point == expected, "Incorrect pole reflection")
            try measurements.observe(point, expected: expected, label: "reflection-\(measurements.count)")
        }
        // Cross the pole continuously in physical position, despite the 180°
        // longitude jump on either side. The middle sample is the pole itself.
        let origin = Coordinate(latitude: 80, longitude: 20)
        let points = try [9.999999, 10, 10.000001].map {
            try AngularMapping.inverse(origin: origin, offset: Offset(latitude: $0, longitude: 0))
        }
        try Probe.check(Probe.chord(points[0], points[1]) < 0.12
            && Probe.chord(points[1], points[2]) < 0.12, "Pole crossing teleports")
    }

    static func checkLoopsAndPoles() throws {
        let origin = Coordinate(latitude: 80, longitude: 20)
        let aliasOrigin = Coordinate(latitude: 30, longitude: 12.123456789)
        let west = try AngularMapping.forward(origin: aliasOrigin, point: Coordinate(latitude: 40, longitude: -180))
        let east = try AngularMapping.forward(origin: aliasOrigin, point: Coordinate(latitude: 40, longitude: 180))
        try Probe.check(west == east, "Longitude aliases must have identical stored offsets")
        let route = [
            Offset(latitude: 0, longitude: 0), Offset(latitude: 20, longitude: 30),
            Offset(latitude: 30, longitude: -60), Offset(latitude: 0, longitude: 0),
        ]
        let moved = try route.map { try AngularMapping.inverse(origin: origin, offset: $0) }
        try Probe.check(moved.first == moved.last, "Closed loop opens after relocation")
        // Document the limitation too: different offsets can become the same
        // physical pole. Reflection is not a rigid or one-to-one route movement.
        let first = try AngularMapping.inverse(origin: origin, offset: Offset(latitude: 10, longitude: -60))
        let second = try AngularMapping.inverse(origin: origin, offset: Offset(latitude: 10, longitude: 60))
        try Probe.check(Probe.chord(first, second) < 1e-6, "Expected pole collapse")
        for latitude in [-90.0, 90] {
            let poleOrigin = Coordinate(latitude: latitude, longitude: 45)
            for longitude in [-180.0, 0, 45, 180] {
                let pole = Coordinate(latitude: latitude, longitude: longitude)
                let zero = try AngularMapping.forward(origin: poleOrigin, point: pole)
                try Probe.check(zero.latitude.bitPattern == 0 && zero.longitude.bitPattern == 0, "Pole alias zero")
                let decoded = try AngularMapping.inverse(origin: poleOrigin, offset: zero)
                try Probe.check(decoded == poleOrigin, "Zero offset changes pole reference meridian")
            }
        }
    }

    static func checkRejections() throws -> Int {
        let origin = Coordinate(latitude: 0, longitude: 0)
        var count = 0
        for invalid in [
            Coordinate(latitude: .nan, longitude: 0), Coordinate(latitude: 91, longitude: 0),
            Coordinate(latitude: 0, longitude: .infinity), Coordinate(latitude: 0, longitude: 181),
        ] {
            try Probe.rejects { _ = try AngularMapping.forward(origin: invalid, point: origin) }
            try Probe.rejects { _ = try AngularMapping.forward(origin: origin, point: invalid) }
            try Probe.rejects {
                _ = try AngularMapping.inverse(origin: invalid, offset: Offset(latitude: 0, longitude: 0))
            }
            count += 3
        }
        for invalid in [
            Offset(latitude: .nan, longitude: 0), Offset(latitude: 0, longitude: .infinity),
            Offset(latitude: 180.000001, longitude: 0), Offset(latitude: -180.000001, longitude: 0),
            Offset(latitude: 0, longitude: 180.000001), Offset(latitude: 0, longitude: -180.000001),
        ] {
            try Probe.rejects { _ = try AngularMapping.inverse(origin: origin, offset: invalid) }
            count += 1
        }
        return count
    }

    static func checkRelocationLimits() throws {
        let original = Coordinate(latitude: 0, longitude: 0)
        let nearby = [
            Coordinate(latitude: 89.999999, longitude: 0),
            Coordinate(latitude: 89.999999, longitude: 180),
        ]
        let offsets = try nearby.map { try AngularMapping.forward(origin: original, point: $0) }
        let moved = try offsets.map {
            try AngularMapping.inverse(origin: Coordinate(latitude: -10, longitude: 0), offset: $0)
        }
        try Probe.check(Probe.chord(nearby[0], nearby[1]) < 0.25, "Original pole neighbors")
        try Probe.check(Probe.chord(moved[0], moved[1]) > 2_000_000, "Expected angular relocation gap")

        let origin = Coordinate(latitude: 80, longitude: 20)
        let retained = Offset(latitude: 20, longitude: 0)
        let materialized = try AngularMapping.inverse(origin: origin, offset: retained)
        let reencoded = try AngularMapping.forward(origin: origin, point: materialized)
        try Probe.check(reencoded != retained, "Reflection has more than one angular representation")
        // Re-encoding a reflected endpoint would lose the authored coordinate
        // interpretation. Origin overrides must retain the original offsets.
        let restored = try AngularMapping.inverse(origin: original, offset: retained)
        try Probe.check(restored == Coordinate(latitude: 20, longitude: 0), "Retained offset returns correctly")
    }
}
