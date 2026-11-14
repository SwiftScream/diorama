import DioramaCore
import DioramaURLSession
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct URLSessionFailureTests {
    @Test(arguments: [Int.min, -987_654, 0, 987_654, Int.max])
    func `unknown codes survive native capture persistence and reconstruction`(_ code: Int) throws {
        let reporter = try reporter()
        let error = NSError(domain: NSURLErrorDomain, code: code)
        let value = try URLSessionFailure.capture(error, reporter: reporter).value
        #expect(value.code == code)
        #expect(try value == URLSessionFailure(domain: NSURLErrorDomain, code: code))
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(URLSessionFailure.self, from: data)
        #expect(decoded == value)
        let materialized = decoded.makeError()
        #expect(materialized is URLError)
        let first = materialized as NSError
        let second = decoded.makeError() as NSError
        #expect(first !== second)
        #expect(first !== error)
        #expect(first.domain == NSURLErrorDomain)
        #expect(first.code == code)
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test(arguments: [NSURLErrorDomain, NSPOSIXErrorDomain])
    func `supported metadata stays in the snapshot without key or domain interpretation`(_ domain: String) throws {
        let url = try #require(URL(string: "https://example.invalid/a?x=%2f&x=%2F"))
        let error = NSError(domain: domain, code: URLError.timedOut.rawValue, userInfo: [
            NSURLErrorFailingURLErrorKey: url,
            "text": "independent URL spelling",
            "nested": ["items": [NSNumber(value: Int64.max), true]],
            NSLocalizedDescriptionKey: "Explicit native description",
        ])
        let reporter = try reporter()
        let value = try URLSessionFailure.capture(error, reporter: reporter).value
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(URLSessionFailure.self, from: data)
        #expect(decoded == value)
        let materialized = decoded.makeError()
        let replay = materialized as NSError
        #expect(replay.domain == domain)
        #expect(replay.code == error.code)
        #expect((replay.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString == url.absoluteString)
        #expect(replay.userInfo["text"] as? String == "independent URL spelling")
        #expect(replay.userInfo[NSLocalizedDescriptionKey] as? String == "Explicit native description")
        let nested = try #require(replay.userInfo["nested"] as? [String: [NSNumber]])
        #expect(nested["items"]?.first?.int64Value == Int64.max)
        #expect(nested["items"]?.last?.boolValue == true)
        if domain == NSURLErrorDomain {
            let native = try #require(materialized as? URLError)
            #expect(native.code == .timedOut)
            #expect(native.failingURL == url)
        } else {
            #expect(type(of: materialized) == NSError.self)
            #expect(materialized as? URLError == nil)
        }
        #expect(try URLSessionFailure.capture(materialized, reporter: reporter).value == value)
        #expect(reporter.freeze().diagnostics.isEmpty)
    }

    @Test
    func `omissions expose only sorted keys and types and retain healthy siblings`() throws {
        let reporter = try reporter()
        let underlying = NSError(domain: "secret-marker", code: 9)
        let object = DescriptionTrap()
        let original = NSError(domain: NSURLErrorDomain, code: -1009, userInfo: [
            "safe": ["secret-marker", "retained"],
            "nested": ["unsupported": object],
            "object": object,
            "oversized": String(repeating: "s", count: 4097),
            NSUnderlyingErrorKey: underlying,
        ])
        let value = try URLSessionFailure.capture(original, reporter: reporter).value
        let replay = value.makeError() as NSError
        #expect(replay.userInfo.keys.sorted() == ["safe"])
        #expect(replay.userInfo["safe"] as? [String] == ["secret-marker", "retained"])
        let report = reporter.freeze()
        let omitted = report.diagnostics.compactMap { entry -> String? in
            guard case let .nativeErrorMetadataOmitted(key, type) = entry.diagnostic.issue else {
                Issue.record("Expected metadata omission")
                return nil
            }
            #expect(!type.isEmpty)
            #expect(entry.diagnostic.recordingImpact == .none)
            return key
        }
        #expect(omitted == [NSUnderlyingErrorKey, "nested", "object", "oversized"].sorted())
        #expect(report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("secret-marker"))
        #expect(original.userInfo["object"] as? NSObject === object)
        #expect(original.userInfo[NSUnderlyingErrorKey] as? NSError === underlying)
    }

    @Test
    func `unsupported scalar and collection values use shared omission rules`() throws {
        let reporter = try reporter()
        let invalid: [Any] = [
            Array(repeating: 1, count: 33), Data(repeating: 0, count: 16385),
            NSNumber(value: Double.infinity), NSNumber(value: UInt64.max),
        ]
        for object in invalid {
            let error = NSError(domain: "CustomError", code: 42, userInfo: ["custom": object, "safe": 7])
            let value = try URLSessionFailure.capture(error, reporter: reporter).value
            #expect((value.makeError() as NSError).userInfo.keys.sorted() == ["safe"])
        }
        let report = reporter.freeze()
        #expect(report.diagnostics.count == invalid.count)
        #expect(report.recordingHealth.isHealthy)
    }

    @Test
    func `capture redacts before normalization and authored admission only validates`() throws {
        let reporter = try reporter()
        let url = try #require(URL(string: "https://example.invalid/?token=secret-marker"))
        let replacement = try #require(URL(string: "https://example.invalid/fixture"))
        let original = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: [
            NSURLErrorFailingURLErrorKey: url, "authorization": "secret-marker", "count": 7,
        ])
        let policy = ValuePreparation<URLSessionFailure>(redact: { value in
            let error = value.makeError() as NSError
            var metadata = error.userInfo
            metadata.removeValue(forKey: "authorization")
            metadata[NSURLErrorFailingURLErrorKey] = replacement
            return try URLSessionFailure.capture(
                NSError(domain: error.domain, code: error.code, userInfo: metadata), reporter: reporter).value
        }, normalize: { value in
            #expect((value.makeError() as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL == replacement)
            return value
        }, validate: { value in
            #expect((value.makeError() as NSError).userInfo["authorization"] == nil)
            #expect((value.makeError() as NSError).userInfo["count"] as? Int == 7)
        })
        let prepared = try URLSessionFailure.capture(original, preparation: policy, reporter: reporter)
        let data = try JSONEncoder().encode(prepared.value)
        #expect(try !#require(String(data: data, encoding: .utf8)).contains("secret-marker"))
        let decoded = try JSONDecoder().decode(URLSessionFailure.self, from: data)
        #expect(try policy.admitPrepared(decoded).value == prepared.value)
        #expect(original.userInfo[NSURLErrorFailingURLErrorKey] as? URL == url)
        #expect(original.userInfo["authorization"] as? String == "secret-marker")
        #expect(reporter.freeze().diagnostics.isEmpty)
        let validateOnly = ValuePreparation<URLSessionFailure>(redact: { _ in throw TestError.secret })
        #expect(try validateOnly.admitPrepared(decoded).value == decoded)
    }

    @Test
    func `failed conversion and preparation retain safe unhealthy evidence without changing live errors`() throws {
        for domain in ["", String(repeating: "a", count: 257)] {
            let reporter = try reporter()
            #expect(throws: URLSessionFailureError.invalidSnapshot) {
                try URLSessionFailure(domain: domain, code: -1001)
            }
            #expect(throws: PreparationFailure.self) {
                try URLSessionFailure.capture(NSError(domain: domain, code: -1001), reporter: reporter)
            }
            let report = reporter.freeze()
            #expect(report.diagnostics.map(\.diagnostic.issue) == [.conversionFailed])
            #expect(!report.recordingHealth.isHealthy)
        }
        let reporter = try reporter()
        let original = NSError(domain: NSURLErrorDomain, code: -1001,
                               userInfo: [NSLocalizedDescriptionKey: "secret-marker"])
        let policy = ValuePreparation<URLSessionFailure>(redact: { _ in throw TestError.secret })
        #expect(throws: PreparationFailure.self) {
            try URLSessionFailure.capture(original, preparation: policy, reporter: reporter)
        }
        let report = reporter.freeze()
        #expect(report.diagnostics.last?.diagnostic.issue == .preparationFailed(.redaction))
        #expect(!report.recordingHealth.isHealthy)
        #expect(!String(describing: report).contains("secret-marker"))
        #expect(original.userInfo[NSLocalizedDescriptionKey] as? String == "secret-marker")
    }

    private func reporter() throws -> DiagnosticReporter {
        try DiagnosticReporter(scenarioID: ScenarioID(rawValue: "urlsession-failure"),
                               definition: ScenarioDefinition(attachments: []))
    }
}

private enum TestError: Error { case secret }

private final class DescriptionTrap: NSObject {
    override var description: String {
        Issue.record("Native object descriptions must never be rendered")
        return "secret-marker"
    }
}
