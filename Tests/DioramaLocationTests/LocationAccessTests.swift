import CoreLocation
@testable import DioramaLocation
import Testing

struct LocationAccessTests {
    @Test
    func `known when in use status remains representable on macOS`() throws {
        let permission = try #require(CLAuthorizationStatus(rawValue: 4))
        let state = LocationAccessState(
            servicesEnabled: true,
            permission: permission,
            accuracy: .fullAccuracy)

        #expect(state.permission.rawValue == 4)
    }

    @Test
    func `access observation retains independent native values`() {
        let state = LocationAccessState(
            servicesEnabled: false,
            permission: .authorizedAlways,
            accuracy: .reducedAccuracy)

        #expect(state.servicesEnabled == false)
        #expect(state.permission == .authorizedAlways)
        #expect(state.accuracy == .reducedAccuracy)
        #expect(state != LocationAccessState(
            servicesEnabled: true,
            permission: .authorizedAlways,
            accuracy: .reducedAccuracy))
    }
}
