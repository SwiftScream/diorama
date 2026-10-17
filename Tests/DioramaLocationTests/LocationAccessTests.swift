import CoreLocation
@testable import DioramaLocation
import Testing

struct LocationAccessTests {
    @Test(arguments: [
        (LocationPermission.notDetermined, Int32(0)), (.restricted, 1), (.denied, 2), (.always, 3),
    ])
    func `replay presents platform independent native permissions`(_ permission: LocationPermission, expected: Int32) {
        let recorded = LocationRecordedAccessState(servicesEnabled: false, permission: permission, accuracy: .reduced)
        let native = LocationAccessState(recorded)
        #expect(native.permission.rawValue == expected)
        #expect(!native.servicesEnabled)
        #expect(native.accuracy == .reducedAccuracy)
        #expect(recorded.permission == permission)
    }

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
