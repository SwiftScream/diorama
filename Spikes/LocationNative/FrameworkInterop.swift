import CloudKit
import CoreLocation
import Foundation
import MapKit
import ObjectiveC.runtime

private var altitudeKey: UInt8 = 0
private var floorKey: UInt8 = 0
private var floorLevelKey: UInt8 = 0

/// A genuine subclass experiment. Both subclasses are unsupported by Apple's
/// documentation; they are here only to test the runtime behavior.
final class ReplayFloor: CLFloor, @unchecked Sendable {
    private let replayLevel: Int

    init(level: Int) {
        replayLevel = level
        super.init()
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var level: Int {
        replayLevel
    }

    override func copy(with _: NSZone? = nil) -> Any {
        ReplayFloor(level: replayLevel)
    }
}

final class ReplayLocation: CLLocation, @unchecked Sendable {
    // Required by the inherited class property; Swift cannot override it with static.
    // swiftlint:disable:next static_over_final_class
    override class var supportsSecureCoding: Bool {
        true
    }

    private let replayEllipsoidalAltitude: CLLocationDistance
    private let replayFloor: CLFloor

    init(backing: CLLocation, ellipsoidalAltitude: CLLocationDistance, floor: CLFloor) {
        replayEllipsoidalAltitude = ellipsoidalAltitude
        replayFloor = floor
        if let source = backing.sourceInformation {
            super.init(
                coordinate: backing.coordinate, altitude: backing.altitude,
                horizontalAccuracy: backing.horizontalAccuracy,
                verticalAccuracy: backing.verticalAccuracy,
                course: backing.course, courseAccuracy: backing.courseAccuracy,
                speed: backing.speed, speedAccuracy: backing.speedAccuracy,
                timestamp: backing.timestamp, sourceInfo: source)
        } else {
            super.init(
                coordinate: backing.coordinate, altitude: backing.altitude,
                horizontalAccuracy: backing.horizontalAccuracy,
                verticalAccuracy: backing.verticalAccuracy,
                course: backing.course, courseAccuracy: backing.courseAccuracy,
                speed: backing.speed, speedAccuracy: backing.speedAccuracy,
                timestamp: backing.timestamp)
        }
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var classForCoder: AnyClass {
        CLLocation.self
    }

    override func encode(with coder: NSCoder) {
        print("diagnostic: secure archive drops replay ellipsoidal altitude and floor")
        super.encode(with: coder)
    }

    override var ellipsoidalAltitude: CLLocationDistance {
        replayEllipsoidalAltitude
    }

    override var floor: CLFloor? {
        replayFloor
    }

    override func copy(with _: NSZone? = nil) -> Any {
        ReplayLocation(backing: self, ellipsoidalAltitude: replayEllipsoidalAltitude, floor: replayFloor)
    }
}

extension CLLocation {
    @objc(dioramaReplayEllipsoidalAltitude)
    func dioramaReplayEllipsoidalAltitude() -> CLLocationDistance {
        if let value = objc_getAssociatedObject(self, &altitudeKey) as? NSNumber {
            return value.doubleValue
        }
        return dioramaReplayEllipsoidalAltitude()
    }

    @objc(dioramaReplayFloor)
    func dioramaReplayFloor() -> CLFloor? {
        if let value = objc_getAssociatedObject(self, &floorKey) as? CLFloor {
            return value
        }
        return dioramaReplayFloor()
    }
}

extension CLFloor {
    @objc(dioramaReplayLevel)
    func dioramaReplayLevel() -> Int {
        if let value = objc_getAssociatedObject(self, &floorLevelKey) as? NSNumber {
            return value.intValue
        }
        return dioramaReplayLevel()
    }
}

func exchange(_ type: AnyClass, _ original: String, _ replacement: String) {
    guard let first = class_getInstanceMethod(type, NSSelectorFromString(original)),
          let second = class_getInstanceMethod(type, NSSelectorFromString(replacement))
    else { fatalError("method missing: \(original), \(replacement)") }
    method_exchangeImplementations(first, second)
}

let native = CLLocation(
    coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
    altitude: 10,
    horizontalAccuracy: 1,
    verticalAccuracy: 1,
    timestamp: Date(timeIntervalSince1970: 1_700_000_000))
let strategy = CommandLine.arguments.dropFirst().first ?? ""
let mode = CommandLine.arguments.dropFirst(2).first ?? ""
let replay: CLLocation

switch strategy {
case "native":
    replay = native
case "subclass":
    replay = ReplayLocation(backing: native, ellipsoidalAltitude: 20, floor: ReplayFloor(level: 3))
case "swizzle":
    exchange(CLLocation.self, "ellipsoidalAltitude", "dioramaReplayEllipsoidalAltitude")
    exchange(CLLocation.self, "floor", "dioramaReplayFloor")
    exchange(CLFloor.self, "level", "dioramaReplayLevel")
    let floor = CLFloor()
    objc_setAssociatedObject(floor, &floorLevelKey, NSNumber(value: 3), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(native, &altitudeKey, NSNumber(value: 20), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    objc_setAssociatedObject(native, &floorKey, floor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    replay = native
default:
    fatalError("unknown strategy")
}

func describe(_ location: CLLocation) {
    print("type:", type(of: location), "coordinate:", location.coordinate.latitude,
          "altitude:", location.altitude, "ellipsoid:", location.ellipsoidalAltitude,
          "floor:", location.floor?.level as Any)
}

print("input:")
describe(replay)

switch mode {
case "distance":
    let other = CLLocation(latitude: 40.7128, longitude: -74.006)
    print("native receiver to replay:", other.distance(from: replay))
    print("native receiver to native:", other.distance(from: native))
    print("replay receiver to native:", replay.distance(from: other))
case "map-item":
    if #available(macOS 26, *) {
        let item = MKMapItem(location: replay, address: nil)
        print("map item location:")
        describe(item.location)
    }
case "reverse-request":
    if #available(macOS 26, *) {
        let request = MKReverseGeocodingRequest(location: replay)
        print("request accepted:", request != nil)
        if let request {
            print("request location:")
            describe(request.location)
        }
    }
case "cloudkit-sort":
    let descriptor = CKLocationSortDescriptor(key: "position", relativeLocation: replay)
    print("sort location:")
    describe(descriptor.relativeLocation)
case "cloudkit-record":
    let record = CKRecord(recordType: "Spike")
    record["position"] = replay
    print("record location:")
    if let value = record["position"] as? CLLocation {
        describe(value)
    }
case "copy":
    print("copy:")
    guard let copied = replay.copy() as? CLLocation else {
        fatalError("CLLocation.copy() returned another type")
    }
    describe(copied)
case "archive":
    do {
        let data = try NSKeyedArchiver.archivedData(withRootObject: replay, requiringSecureCoding: true)
        let decoded = try NSKeyedUnarchiver.unarchivedObject(ofClass: CLLocation.self, from: data)
        print("archive round trip:")
        if let decoded {
            describe(decoded)
        }
    } catch {
        print("archive failed:", error)
    }
default:
    fatalError("unknown mode")
}
