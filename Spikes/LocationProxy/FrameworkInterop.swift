import CloudKit
import CoreLocation
import Foundation
import MapKit

final class ForwardingLocation: NSObject, NSCopying, NSSecureCoding {
    static var supportsSecureCoding: Bool {
        true
    }

    let backing: CLLocation
    let replayEllipsoidalAltitude: Double

    init(backing: CLLocation, ellipsoidalAltitude: Double) {
        self.backing = backing
        replayEllipsoidalAltitude = ellipsoidalAltitude
        super.init()
    }

    required init?(coder: NSCoder) {
        guard let location = coder.decodeObject(of: CLLocation.self, forKey: "backing") else { return nil }
        backing = location
        replayEllipsoidalAltitude = coder.decodeDouble(forKey: "ellipsoidalAltitude")
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(backing, forKey: "backing")
        coder.encode(replayEllipsoidalAltitude, forKey: "ellipsoidalAltitude")
    }

    override func replacementObject(for _: NSCoder) -> Any? {
        backing
    }

    func copy(with _: NSZone? = nil) -> Any {
        guard let copied = backing.copy() as? CLLocation else { fatalError("Native location copy changed type") }
        return ForwardingLocation(backing: copied, ellipsoidalAltitude: replayEllipsoidalAltitude)
    }

    @objc dynamic var ellipsoidalAltitude: Double {
        replayEllipsoidalAltitude
    }

    override func forwardingTarget(for _: Selector!) -> Any? {
        backing
    }

    override func isKind(of aClass: AnyClass) -> Bool {
        aClass == CLLocation.self || super.isKind(of: aClass)
    }
}

let backing = CLLocation(
    coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
    altitude: 10, horizontalAccuracy: 1, verticalAccuracy: 1,
    timestamp: Date(timeIntervalSince1970: 1_700_000_000))
guard let proxy = ForwardingLocation(backing: backing, ellipsoidalAltitude: 20) as AnyObject as? CLLocation
else { fatalError("Proxy did not pass the CLLocation runtime cast") }
let mode = CommandLine.arguments.dropFirst().first ?? ""
print("input:", type(of: proxy), proxy.coordinate.latitude, proxy.ellipsoidalAltitude)

switch mode {
case "distance":
    let other = CLLocation(latitude: 40.7128, longitude: -74.006)
    print("native receiver distance to proxy:", other.distance(from: proxy))
    print("native receiver distance to backing:", other.distance(from: backing))
    print("proxy receiver distance to native:", proxy.distance(from: other))
case "cloudkit-sort":
    let descriptor = CKLocationSortDescriptor(key: "position", relativeLocation: proxy)
    print("sort location:", type(of: descriptor.relativeLocation),
          descriptor.relativeLocation.coordinate.latitude, descriptor.relativeLocation.ellipsoidalAltitude)
case "cloudkit-record":
    let record = CKRecord(recordType: "Spike")
    record["position"] = proxy
    print("record value:", type(of: record["position"] as Any),
          (record["position"] as? CLLocation)?.ellipsoidalAltitude as Any)
case "map-item":
    if #available(macOS 26, *) {
        let item = MKMapItem(location: proxy, address: nil)
        print("item location:", type(of: item.location),
              item.location.coordinate.latitude, item.location.ellipsoidalAltitude)
    }
case "reverse-request":
    if #available(macOS 26, *) {
        let request = MKReverseGeocodingRequest(location: proxy)
        print("request accepted:", request != nil)
        if let request {
            print("request location:", type(of: request.location),
                  request.location.coordinate.latitude, request.location.ellipsoidalAltitude)
        }
    }
default:
    fatalError("unknown mode")
}
