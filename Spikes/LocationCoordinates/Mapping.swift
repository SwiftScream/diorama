import Foundation

/// Experimental, bounded WGS84 azimuthal-equidistant mapping; no production imports.
enum Mapping {
    static let semimajor = 6_378_137.0
    static let flattening = 1 / 298.257223563
    static let semiminor = semimajor * (1 - flattening)
    static let radians = Double.pi / 180
    static let maximumRadius = 2_500_000.0
    static let maximumLatitude = 90.0
    static let convergence = 1e-12
    static let iterationLimit = 64

    struct Coordinate: Equatable {
        let latitude: Double
        let longitude: Double

        var valid: Bool {
            latitude.isFinite && longitude.isFinite
                && abs(latitude) <= maximumLatitude && abs(longitude) <= 180
        }

        var canonical: Self {
            Self(latitude: cleanZero(latitude), longitude: cleanZero(wrapDegrees(longitude)))
        }
    }

    struct Offset {
        let east: Double
        let north: Double

        var radius: Double {
            hypot(east, north)
        }
    }

    enum Failure: Error {
        case coordinate, offset, outsideRegion, noConvergence
    }

    struct Result<Value> {
        let value: Value
        let iterations: Int
    }

    /// Original implementation of Vincenty's 1975 equations (3)–(21).
    /// https://geodesy.noaa.gov/PUBS_LIB/inverse.pdf
    /// These short, bounded equations are evaluated here, not adopted by the library.
    static func forward(origin: Coordinate, point: Coordinate) throws -> Result<Offset> {
        guard origin.valid, point.valid else { throw Failure.coordinate }
        let origin = origin.canonical
        let point = point.canonical
        // Longitude identifies the origin's reference meridian at a pole,
        // but two representations of that same pole have zero displacement.
        if origin == point || (abs(origin.latitude) == 90 && origin.latitude == point.latitude) {
            return Result(value: Offset(east: 0, north: 0), iterations: 0)
        }
        let reduced1 = atan((1 - flattening) * tan(origin.latitude * radians))
        let reduced2 = atan((1 - flattening) * tan(point.latitude * radians))
        let longitude = wrapDegrees(point.longitude - origin.longitude) * radians
        var lambda = longitude
        for iteration in 1...iterationLimit {
            let step = InverseStep(reduced1: reduced1, reduced2: reduced2, lambda: lambda)
            // Distinct input doubles can collapse to the same reduced latitude.
            // Keep numerical coincidence separate from an antipodal degeneracy.
            if step.sineSigma == 0 {
                guard step.sigma == 0 else { throw Failure.outsideRegion }
                return Result(value: Offset(east: 0, north: 0), iterations: iteration)
            }
            let next = longitude + longitudeCorrection(
                sineAlpha: step.sineAlpha, cosineSquaredAlpha: step.cosineSquaredAlpha,
                sigma: step.sigma, cosineMidpoint: step.cosineMidpoint)
            if abs(next - lambda) <= convergence {
                let final = InverseStep(reduced1: reduced1, reduced2: reduced2, lambda: next)
                let coefficients = coefficients(cosineSquaredAlpha: final.cosineSquaredAlpha)
                let distance = semiminor * coefficients.scale
                    * (final.sigma - deltaSigma(
                        series: coefficients.series, sigma: final.sigma, cosineMidpoint: final.cosineMidpoint))
                guard distance.isFinite, distance >= 0, distance <= maximumRadius else {
                    throw Failure.outsideRegion
                }
                let bearing = atan2(
                    cos(reduced2) * sin(next),
                    cos(reduced1) * sin(reduced2) - sin(reduced1) * cos(reduced2) * cos(next))
                return Result(value: Offset(
                    east: cleanZero(distance * sin(bearing)),
                    north: cleanZero(distance * cos(bearing))), iterations: iteration)
            }
            lambda = next
        }
        throw Failure.noConvergence
    }

    static func inverse(origin: Coordinate, offset: Offset) throws -> Result<Coordinate> {
        guard origin.valid else { throw Failure.coordinate }
        guard offset.east.isFinite, offset.north.isFinite else { throw Failure.offset }
        let distance = offset.radius
        guard distance <= maximumRadius else { throw Failure.outsideRegion }
        if distance == 0 {
            return Result(value: origin.canonical, iterations: 0)
        }
        let bearing = atan2(offset.east, offset.north)
        let reduced = atan((1 - flattening) * tan(origin.latitude * radians))
        let sigma1 = atan2(tan(reduced), cos(bearing))
        let sineAlpha = cos(reduced) * sin(bearing)
        let cosineSquaredAlpha = max(0, 1 - sineAlpha * sineAlpha)
        let coefficients = coefficients(cosineSquaredAlpha: cosineSquaredAlpha)
        let initial = distance / (semiminor * coefficients.scale)
        var sigma = initial
        for iteration in 1...iterationLimit {
            let next = initial + deltaSigma(
                series: coefficients.series, sigma: sigma, cosineMidpoint: cos(2 * sigma1 + sigma))
            if abs(next - sigma) <= convergence {
                let temporary = sin(reduced) * sin(next) - cos(reduced) * cos(next) * cos(bearing)
                let latitude = atan2(
                    sin(reduced) * cos(next) + cos(reduced) * sin(next) * cos(bearing),
                    (1 - flattening) * hypot(sineAlpha, temporary)) / radians
                let lambda = atan2(
                    sin(next) * sin(bearing),
                    cos(reduced) * cos(next) - sin(reduced) * sin(next) * cos(bearing))
                let longitude = origin.longitude + (lambda - longitudeCorrection(
                    sineAlpha: sineAlpha, cosineSquaredAlpha: cosineSquaredAlpha,
                    sigma: next, cosineMidpoint: cos(2 * sigma1 + next))) / radians
                let point = Coordinate(latitude: latitude, longitude: wrapDegrees(longitude)).canonical
                guard point.valid else { throw Failure.outsideRegion }
                return Result(value: point, iterations: iteration)
            }
            sigma = next
        }
        throw Failure.noConvergence
    }

    private struct InverseStep {
        let sineSigma: Double
        let sigma: Double
        let sineAlpha: Double
        let cosineSquaredAlpha: Double
        let cosineMidpoint: Double

        init(reduced1: Double, reduced2: Double, lambda: Double) {
            sineSigma = hypot(
                cos(reduced2) * sin(lambda),
                cos(reduced1) * sin(reduced2) - sin(reduced1) * cos(reduced2) * cos(lambda))
            let cosineSigma = sin(reduced1) * sin(reduced2) + cos(reduced1) * cos(reduced2) * cos(lambda)
            sigma = atan2(sineSigma, cosineSigma)
            sineAlpha = sineSigma == 0 ? 0 : cos(reduced1) * cos(reduced2) * sin(lambda) / sineSigma
            cosineSquaredAlpha = max(0, 1 - sineAlpha * sineAlpha)
            // The equatorial case has zero correction; avoid its 0/0.
            cosineMidpoint = cosineSquaredAlpha == 0
                ? 0 : cosineSigma - 2 * sin(reduced1) * sin(reduced2) / cosineSquaredAlpha
        }
    }

    private static func coefficients(cosineSquaredAlpha: Double) -> (scale: Double, series: Double) {
        let squared = cosineSquaredAlpha * (semimajor * semimajor - semiminor * semiminor) / (semiminor * semiminor)
        return (
            1 + squared / 16384 * (4096 + squared * (-768 + squared * (320 - 175 * squared))),
            squared / 1024 * (256 + squared * (-128 + squared * (74 - 47 * squared))))
    }

    private static func deltaSigma(series: Double, sigma: Double, cosineMidpoint: Double) -> Double {
        let midpointSquared = cosineMidpoint * cosineMidpoint
        let sineSigma = sin(sigma)
        return series * sineSigma * (
            cosineMidpoint + series / 4 * (
                cos(sigma) * (-1 + 2 * midpointSquared)
                    - series / 6 * cosineMidpoint * (-3 + 4 * sineSigma * sineSigma) * (-3 + 4 * midpointSquared)))
    }

    private static func longitudeCorrection(
        sineAlpha: Double, cosineSquaredAlpha: Double, sigma: Double, cosineMidpoint: Double) -> Double
    {
        let coefficient = flattening / 16 * cosineSquaredAlpha * (4 + flattening * (4 - 3 * cosineSquaredAlpha))
        return (1 - coefficient) * flattening * sineAlpha * (
            sigma + coefficient * sin(sigma) * (
                cosineMidpoint + coefficient * cos(sigma) * (-1 + 2 * cosineMidpoint * cosineMidpoint)))
    }

    static func wrapDegrees(_ degrees: Double) -> Double {
        var wrapped = degrees.truncatingRemainder(dividingBy: 360)
        if wrapped < -180 {
            wrapped += 360
        }
        if wrapped >= 180 {
            wrapped -= 360
        }
        return cleanZero(wrapped)
    }

    private static func cleanZero(_ value: Double) -> Double {
        value == 0 ? 0 : value
    }
}
