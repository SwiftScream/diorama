# 003-G01 — genuine `CLLocation` replay candidates

This exploratory spike revisits two ways to deliver a real `CLLocation`
instance with replayed `ellipsoidalAltitude` and `floor.level`. It does not
change the accepted DD16 contract or G01 production code. The
[isolated source](../../Spikes/LocationNative/FrameworkInterop.swift) exercises
a `CLLocation` subclass with overridden getters and `copy(with:)`, and an
ordinary `CLLocation` with associated replay values exposed by process-wide
Objective-C getter swizzling. Both approaches also need a `CLFloor` subclass or
swizzled `CLFloor.level` to represent an arbitrary floor.

Apple explicitly says not to subclass [`CLLocation`](https://developer.apple.com/documentation/corelocation/cllocation?changes=la__2_8),
and says not to create or subclass [`CLFloor`](https://developer.apple.com/documentation/corelocation/clfloor?changes=l__4_8).
These are runtime experiments, not supported Core Location extension points.

The spike ran on macOS 27.0.1 with the Xcode 27.0.0 SDK. Compile with
`swiftc -warnings-as-errors Spikes/LocationNative/FrameworkInterop.swift -o
/tmp/diorama-native-framework-spike`, then invoke the binary with one strategy
(`native`, `subclass`, or `swizzle`) and one mode (`distance`, `map-item`,
`reverse-request`, `cloudkit-sort`, `cloudkit-record`, `copy`, or `archive`).
Each invocation is a separate process. The API calls do not start a network
request or save any data to CloudKit.

The input uses `(37.7749, -122.4194)`, orthometric altitude `10`, replayed
ellipsoidal altitude `20`, and replayed floor level `3`. Native distance is
compared with `(40.7128, -74.006)`.

| Operation | Subclass | Native object with swizzled getters |
| --- | --- | --- |
| Direct getters | Reports ellipsoidal altitude `20` and floor `3`. | Same; an ordinary unmarked object retains its native getters. |
| `CLLocation.distance(from:)` in both directions | Returns the native expected distance, about `4,139,145.472 m`. | Same. The earlier independent-object proxy failed this check. |
| `MKMapItem(location:address:)` | Accepts the object; returned location has altitude `0`, ellipsoidal altitude `0`, and no floor. A native baseline also loses orthometric altitude `10`, so this API reconstructs a reduced location even without a replay override. | Same. |
| `MKReverseGeocodingRequest(location:)` construction and readback | Retains the subclass and both replay fields. | Retains the native object and both replay fields. |
| `CKLocationSortDescriptor` and local `CKRecord` field readback | Retain both replay fields after the subclass overrides `copy(with:)`. Before that override, both lost the fields. | Lose both replay fields when copied; retain ordinary altitude. |
| Direct `copy()` | Preserves both replay fields with an explicit subclass override. Without it, inherited copying loses them. | Loses both replay fields. A process-wide copy hook or other intervention would be needed. |
| Secure keyed archive round trip | An override of `classForCoder` identifies the archive as native `CLLocation`; inherited native encoding then decodes to native `CLLocation`. The prototype prints a loss diagnostic, and the decoded object has ellipsoidal altitude `0` and no floor. | Encodes and decodes as native `CLLocation`, losing both replay fields. |

The subclass is the stronger of these two candidates for ordinary consumer
calls: it is a genuine `CLLocation`, native distance works, and a local copy
override preserves replay data through the tested CloudKit values. It still
violates Apple's explicit subclassing guidance, and floor needs another
unsupported technique. The swizzled approach keeps an ordinary native class
but changes Core Location getters for the whole process, affects unrelated
objects, and loses replay data under routine copying. Neither approach has an
established compatibility guarantee for arbitrary first-party frameworks.

The subclass can therefore use the approved lossy secure-archive policy:
advertise `CLLocation` as its coding class, emit a diagnostic from `encode(with:)`,
then call native encoding. The prototype prints the diagnostic; production would
need to integrate it with Diorama's diagnostic machinery. The consumer opts in
through the attachment's replay-fidelity options. The experiment verifies one
local archive round trip, not every archiver or framework coding path.

Native `CLLocation` construction with valid vertical accuracy, orthometric
altitude `10`, and the San Francisco coordinate reported
`ellipsoidalAltitude == 0`. The public initializer does not reconstruct the
recorded value `20`. Recording and passthrough can return their original
native objects. Replay can use an ordinary native object when the recorded
ellipsoidal altitude equals what native reconstruction reports and the floor
is absent; otherwise exact replay needs the subclass or another unsupported
mechanism. A non-nil floor is not the only reason to use the subclass. DD16's
[native consumer amendment](../design-decisions/16-location-system.md#native-consumer-locations-with-opt-in-replay-fidelity--owner-approved-2026-10-17)
selects default-off, independent replay options; enabling ellipsoidal-altitude
fidelity uses the subclass for every replay location, and enabling floor
fidelity uses it only for a recorded non-nil floor.

Only local construction and readback were tested. No geocoding lookup, CloudKit
server operation, iOS run, concurrency stress, alternate archive paths, or
future SDK behavior was tested. No production API or dependency was changed.
