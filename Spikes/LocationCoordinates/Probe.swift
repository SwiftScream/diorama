import Foundation

@main
enum Probe {
    typealias Coordinate = Mapping.Coordinate
    typealias Offset = Mapping.Offset

    static let errorBudget = 0.01

    struct CheckFailure: Error, CustomStringConvertible {
        let description: String
    }

    struct Fixture {
        let name: String
        let origin: Coordinate
        let point: Coordinate
        let offset: Offset

        init(line: Substring) throws {
            let fields = line.split(separator: ",")
            guard fields.count == 7 else { throw CheckFailure(description: "Malformed fixture: \(line)") }
            let numbers = try fields.dropFirst().map { field in
                guard let number = Double(field), number.isFinite else {
                    throw CheckFailure(description: "Malformed number: \(field)")
                }
                return number
            }
            name = String(fields[0])
            origin = Coordinate(latitude: numbers[0], longitude: numbers[1])
            point = Coordinate(latitude: numbers[2], longitude: numbers[3])
            offset = Offset(east: numbers[4], north: numbers[5])
        }
    }

    struct Maximum {
        var value = 0.0
        var fixture = "none"

        mutating func observe(_ value: Double, name: String) throws {
            try check(value.isFinite && value <= errorBudget, "\(name): error \(value) m exceeds \(errorBudget) m")
            if value > self.value {
                self.value = value
                fixture = name
            }
        }
    }

    struct Measurements {
        var forwardError = Maximum()
        var inverseError = Maximum()
        var roundTripError = Maximum()
        var reencodedError = Maximum()
        var forwardIterations = 0
        var inverseIterations = 0
        var count = 0
        var output = "id,east,north,latitude,longitude\n"

        mutating func evaluate(_ fixture: Fixture) throws {
            let forward = try context(fixture.name, "forward") {
                try Mapping.forward(origin: fixture.origin, point: fixture.point)
            }
            let inverse = try context(fixture.name, "inverse") {
                try Mapping.inverse(origin: fixture.origin, offset: fixture.offset)
            }
            let roundTrip = try context(fixture.name, "position round trip") {
                try Mapping.inverse(origin: fixture.origin, offset: forward.value)
            }
            let reencoded = try context(fixture.name, "offset round trip") {
                try Mapping.forward(origin: fixture.origin, point: inverse.value)
            }
            try forwardError.observe(
                hypot(forward.value.east - fixture.offset.east, forward.value.north - fixture.offset.north),
                name: fixture.name)
            try inverseError.observe(chord(inverse.value, fixture.point), name: fixture.name)
            try roundTripError.observe(chord(roundTrip.value, fixture.point), name: fixture.name)
            try reencodedError.observe(
                hypot(reencoded.value.east - fixture.offset.east, reencoded.value.north - fixture.offset.north),
                name: fixture.name)
            forwardIterations = max(forwardIterations, forward.iterations)
            inverseIterations = max(inverseIterations, inverse.iterations)
            output += "\(fixture.name),\(forward.value.east),\(forward.value.north),"
                + "\(inverse.value.latitude),\(inverse.value.longitude)\n"
            count += 1
        }

        func report(rejections: Int) {
            print("PASS: \(count) reference/relocation pairs; \(rejections) rejection checks")
            for (label, maximum) in [
                ("forward vector", forwardError), ("inverse position", inverseError),
                ("position round trip", roundTripError), ("offset round trip", reencodedError),
            ] {
                print("maximum \(label) error: \(maximum.value) m (\(maximum.fixture))")
            }
            print("maximum iterations: forward \(forwardIterations), inverse \(inverseIterations)")
        }
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        try check(arguments.count == 3, "Usage: probe <fixture-directory> <results.csv>")
        var measurements = Measurements()
        for filename in ["reference.csv", "relocation.csv", "polar.csv", "regional.csv"] {
            let contents = try String(contentsOfFile: arguments[1] + "/" + filename, encoding: .utf8)
            let lines = contents.split(separator: "\n").dropFirst()
            try check(!lines.isEmpty, "Empty reference file")
            for line in lines {
                try measurements.evaluate(Fixture(line: line))
            }
        }
        let rejections = try checkBoundaries()
        try measurements.output.write(toFile: arguments[2], atomically: true, encoding: .utf8)
        measurements.report(rejections: rejections)
        try AngularProbe.run(outputPath: arguments[2] + ".angular")
    }

    static func checkBoundaries() throws -> Int {
        let zero = Coordinate(latitude: 0, longitude: 0)
        var rejectionCount = 0
        for invalid in [
            Coordinate(latitude: .nan, longitude: 0), Coordinate(latitude: 0, longitude: .infinity),
            Coordinate(latitude: 0, longitude: -180.000001), Coordinate(latitude: 0, longitude: 180.000001),
            Coordinate(latitude: 90.000001, longitude: 0), Coordinate(latitude: -90.000001, longitude: 0),
            Coordinate(latitude: 91, longitude: 0),
        ] {
            try rejects { _ = try Mapping.forward(origin: invalid, point: zero) }
            try rejects { _ = try Mapping.forward(origin: zero, point: invalid) }
            try rejects { _ = try Mapping.inverse(origin: invalid, offset: Offset(east: 0, north: 0)) }
            rejectionCount += 3
        }
        for offset in [
            Offset(east: .nan, north: 0), Offset(east: 0, north: .infinity),
            Offset(east: .greatestFiniteMagnitude, north: .greatestFiniteMagnitude),
            Offset(east: Mapping.maximumRadius + 0.01, north: 0),
            Offset(east: 0, north: -Mapping.maximumRadius - 0.01),
            Offset(east: Mapping.maximumRadius * 0.8, north: Mapping.maximumRadius * 0.8),
        ] {
            try rejects { _ = try Mapping.inverse(origin: zero, offset: offset) }
            rejectionCount += 1
        }
        // Long and antipodal lines never silently return a spherical fallback.
        for point in [
            Coordinate(latitude: 0, longitude: 170), Coordinate(latitude: 0, longitude: 180),
            Coordinate(latitude: 0.5, longitude: 179.5),
        ] {
            try rejects { _ = try Mapping.forward(origin: zero, point: point) }
            rejectionCount += 1
        }
        try checkPoles()
        let boundary = try Mapping.inverse(origin: zero, offset: Offset(east: Mapping.maximumRadius, north: 0))
        let boundaryOffset = try Mapping.forward(origin: zero, point: boundary.value)
        try check(abs(boundaryOffset.value.east - Mapping.maximumRadius) < 0.001, "Radius boundary")
        let alias = Coordinate(latitude: -0.0, longitude: 180)
        let origin = try Mapping.inverse(origin: alias, offset: Offset(east: -0.0, north: -0.0)).value
        try check(origin.latitude.bitPattern == 0 && origin.longitude == -180, "Canonical origin")
        let offset = try Mapping.forward(origin: alias, point: origin).value
        try check(offset.east.bitPattern == 0 && offset.north.bitPattern == 0, "Canonical zero offset")
        return rejectionCount
    }

    static func checkPoles() throws {
        for latitude in [-90.0, 90.0] {
            let origin = Coordinate(latitude: latitude, longitude: 45)
            for longitude in [-180.0, -45, 0, 180] {
                let offset = try Mapping.forward(
                    origin: origin, point: Coordinate(latitude: latitude, longitude: longitude)).value
                try check(offset.east.bitPattern == 0 && offset.north.bitPattern == 0, "Same pole is zero")
                let point = try Mapping.inverse(origin: origin, offset: offset).value
                try check(point == origin, "Zero offset preserves the pole origin's reference meridian")
            }
        }
    }

    static func rejects(_ body: () throws -> Void) throws {
        do { try body() } catch is Mapping.Failure { return }
        throw CheckFailure(description: "Expected a mapping rejection")
    }

    static func check(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw CheckFailure(description: message)
        }
    }

    static func context<Value>(_ fixture: String, _ operation: String, _ body: () throws -> Value) throws -> Value {
        do { return try body() } catch {
            throw CheckFailure(description: "\(fixture), \(operation): \(error)")
        }
    }

    /// ECEF chord between nearby positions, in meters. No dependency on the
    /// geodesic solver under test; at centimeter separation arc/chord difference
    /// is negligible. This compares the reference coordinates on the ellipsoid.
    static func chord(_ first: Coordinate, _ second: Coordinate) -> Double {
        func cartesian(_ point: Coordinate) -> SIMD3<Double> {
            let latitude = point.latitude * .pi / 180
            let longitude = point.longitude * .pi / 180
            let eccentricitySquared = Mapping.flattening * (2 - Mapping.flattening)
            let radius = Mapping.semimajor / sqrt(1 - eccentricitySquared * pow(sin(latitude), 2))
            return SIMD3(radius * cos(latitude) * cos(longitude), radius * cos(latitude) * sin(longitude),
                         radius * (1 - eccentricitySquared) * sin(latitude))
        }
        let first = cartesian(first)
        let second = cartesian(second)
        return hypot(hypot(first.x - second.x, first.y - second.y), first.z - second.z)
    }
}
