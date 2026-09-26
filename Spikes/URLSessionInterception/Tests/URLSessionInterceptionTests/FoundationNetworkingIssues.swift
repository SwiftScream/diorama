import Foundation
import Testing

/// Keep native defect assertions executable without failing the stock Linux gate.
/// A repaired runtime fails with an unexpected pass until its expectation is removed.
func withKnownLinuxIssue(_ comment: Comment, affected: Bool = true,
                         sourceLocation: SourceLocation = #_sourceLocation, _ body: () -> Void)
{
    #if os(Linux)
        if affected, ProcessInfo.processInfo.environment["DIORAMA_VERIFY_FOUNDATION_FIXES"] != "1" {
            withKnownIssue(comment, sourceLocation: sourceLocation) { body() }
        } else {
            body()
        }
    #else
        body()
    #endif
}
