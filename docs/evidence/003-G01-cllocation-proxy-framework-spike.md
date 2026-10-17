# 003-G01 — `CLLocation` proxy framework interoperability spike

This is exploratory evidence, not a change to the accepted DD16 location
contract. The [isolated source](../../Spikes/LocationProxy/FrameworkInterop.swift)
creates an `NSObject` wrapper around a valid native `CLLocation`. It forwards
unrecognized Objective-C selectors, overrides `ellipsoidalAltitude`, claims
`CLLocation` in `isKind(of:)`, preserves the override when copied, and substitutes
the native location during keyed archiving. It omits a floor override so that
these calls isolate whether frameworks can use the location wrapper at all.

The spike ran on macOS 27.0.1 with the Xcode 27.0.0 SDK. From the repository
root, compile and invoke each mode separately:

```sh
swiftc -warnings-as-errors Spikes/LocationProxy/FrameworkInterop.swift \
  -o /tmp/diorama-framework-location-spike
/tmp/diorama-framework-location-spike distance
/tmp/diorama-framework-location-spike map-item
/tmp/diorama-framework-location-spike reverse-request
/tmp/diorama-framework-location-spike cloudkit-sort
/tmp/diorama-framework-location-spike cloudkit-record
```

These modes make no network request and do not write to Photos or HealthKit.

The wrapped native location is at `(37.7749, -122.4194)` with orthometric
altitude `10`; the proxy reports ellipsoidal altitude `20`. The comparison
location for distance is `(40.7128, -74.006)`. The proxy casts to
`CLLocation` and its forwarded `coordinate` reads as expected.

| First-party API | Observed result |
| --- | --- |
| [`CLLocation.distance(from:)`](https://developer.apple.com/documentation/corelocation/cllocation/distance%28from%3A%29?changes=__3), called on a native location with the proxy as argument | Returned **8,667,423.676 m**, while passing the wrapped native location returned **4,139,145.472 m**. An earlier prototype with a smaller wrapper returned `0` for the same comparison. The reciprocal call on the proxy returned **4,139,145.472 m** because it forwarded to the wrapped location. The retained `coordinate` getter alone is insufficient for this native method. The implementation mechanism is unknown. |
| [`MKMapItem(location:address:)`](https://developer.apple.com/documentation/mapkit/mkmapitem/init%28location%3Aaddress%3A%29?changes=__5_5) | Accepted the proxy. Its `location` was a native `CLLocation` with correct latitude and ellipsoidal altitude `0`; the proxy override did not survive. This initializer requires macOS 26 or later. |
| [`MKReverseGeocodingRequest(location:)`](https://developer.apple.com/documentation/mapkit/mkreversegeocodingrequest/init%28location%3A%29?changes=_9_7) | Accepted the proxy and retained a wrapper location reporting latitude `37.7749` and ellipsoidal altitude `20`. Only request construction and readback were tested; no lookup was started. This initializer requires macOS 26 or later. |
| [`CKLocationSortDescriptor(key:relativeLocation:)`](https://developer.apple.com/documentation/cloudkit/cklocationsortdescriptor) | Accepted the proxy and retained a wrapper location with ellipsoidal altitude `20`. No CloudKit query or server-side sort was run. |
| [`CKRecord` location field](https://developer.apple.com/documentation/cloudkit/ckrecord) | Accepted the proxy into a local record and returned it with ellipsoidal altitude `20`. CloudKit documents that a record does not locally validate all field constraints; no save was attempted. |

These results show both acceptance and silent incompatibility. In particular,
the native `distance(from:)` result is wrong for a common operation even though
the proxy has the expected public coordinate and can be cast to `CLLocation`.
The differing result between the two prototype builds reinforces that the
wrapper cannot rely on the method's undocumented handling of a nonnative
instance. Passing a proxy through an arbitrary first-party API therefore
cannot be promised as safe. A future explicit conversion to an ordinary native
`CLLocation` could support callers that accept losing floor and independent
ellipsoidal altitude; it would not be a lossless replay value.

This is a macOS result only. The iOS implementation, geocoding network call,
CloudKit server behavior, HealthKit route insertion, and Photos writes were not
tested. No production dependency or runtime workaround was added.
