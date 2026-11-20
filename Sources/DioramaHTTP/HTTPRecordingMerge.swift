import DioramaCore

/// Timing-only re-recording over the setup's prepared initial-request equivalence.
public struct HTTPRecordingMerge<Failure: Sendable>: Sendable {
    /// The same prepared request policy used to select this attachment's replay records.
    public let matcher: HTTPRequestMatcher

    /// Uses standard HTTP match fields unless setup supplies its own policy.
    public init(matcher: HTTPRequestMatcher = .init()) {
        self.matcher = matcher
    }

    /// Pairs equivalent requests in stable occurrence order and retains authored delays
    /// along compatible branches. The result follows fresh invocation order.
    /// Reported paths refer to baseline timing nodes, except correspondence failures,
    /// which identify the input whose equivalence cannot be resolved.
    public func merge(
        baseline: HeaderlessSequentialTrack<HTTPInteraction<Failure>>,
        fresh: HeaderlessSequentialTrack<HTTPInteraction<Failure>>,
        report: (Diagnostic) -> Void) throws -> HeaderlessSequentialTrack<HTTPInteraction<Failure>>
    {
        guard baseline.id == fresh.id else { throw HTTPRecordingMergeError.incompatibleTracks }
        guard !baseline.records.isEmpty else { return fresh }
        var groups = HTTPRequestGroups(matcher: matcher)
        var positions: [Int: [Int]] = [:]
        for (index, record) in baseline.records.enumerated() {
            let group = try groups.group(for: record, report: report)
            positions[group, default: []].append(index)
        }

        var counts: [Int: Int] = [:]
        var paired: Set<Int> = []
        var outcomes: [Diagnostic] = []
        let values = try fresh.records.map { record in
            let group = try groups.group(for: record, report: report)
            let occurrence = counts[group, default: 0]
            let value: HTTPInteraction<Failure>
            if let indices = positions[group], occurrence < indices.count {
                let index = indices[occurrence]
                paired.insert(index)
                counts[group] = occurrence + 1
                value = try preservingOverrides(from: baseline.records[index], in: record.value) { outcomes.append($0) }
            } else {
                value = record.value
            }
            return try ValuePreparation().admitPrepared(value, context: .record(record.identity))
        }
        for (index, record) in baseline.records.enumerated() where !paired.contains(index) {
            let overrides = try HTTPTimingOverrides(record.value)
            overrides.reportOutcomes(in: record.identity) { outcomes.append($0) }
        }
        outcomes.forEach(report)
        return HeaderlessSequentialTrack(id: fresh.id, values: values)
    }

    private func preservingOverrides(
        from record: SequentialRecord<HTTPInteraction<Failure>>, in fresh: HTTPInteraction<Failure>,
        report: (Diagnostic) -> Void) throws -> HTTPInteraction<Failure>
    {
        var overrides = try HTTPTimingOverrides(record.value)
        guard !overrides.paths.isEmpty else { return fresh }
        let result = try HTTPTimingTraversal<Failure> { path, observed in
            overrides.remaining.removeValue(forKey: path) ?? observed
        }.attempt(fresh.result)
        overrides.reportOutcomes(in: record.identity, report: report)
        return try HTTPInteraction(initialRequest: fresh.initialRequest, result: result)
    }
}

/// Structural merge failures contain no request, body, credential, or resource data.
public enum HTTPRecordingMergeError: Error {
    /// Both inputs must belong to the same keyed track.
    case incompatibleTracks
    /// The configured comparison cannot partition the supplied requests into equivalent groups.
    case correspondenceNeedsResolution
}

private struct HTTPTimingOverrides {
    let paths: [HTTPTimingPath]
    var remaining: [HTTPTimingPath: HTTPDelay]

    init<Failure>(_ interaction: HTTPInteraction<Failure>) throws {
        var paths: [HTTPTimingPath] = []
        var delays: [HTTPTimingPath: HTTPDelay] = [:]
        _ = try HTTPTimingTraversal<Failure> { path, delay in
            if delay.milliseconds.isOverride {
                paths.append(path)
                delays[path] = delay
            }
            return delay
        }.attempt(interaction.result)
        self.paths = paths
        remaining = delays
    }

    func reportOutcomes(in record: RecordIdentity, report: (Diagnostic) -> Void) {
        for path in paths {
            let issue = remaining[path] == nil
                ? DiagnosticLabel("http.timing-override-retained")
                : DiagnosticLabel("http.timing-override-obsolete")
            report(Diagnostic(issue: .system(issue),
                              context: .record(record), fieldPath: path.components))
        }
    }
}

/// Assigns group identities in encounter order. Exact projections have a hash lookup.
/// A custom comparator must agree in both directions with every member of exactly one
/// group, or with none. Checking all members prevents order-dependent partial overlaps.
private struct HTTPRequestGroups {
    let matcher: HTTPRequestMatcher
    private var known: [HTTPRequestMatchProjection: Int] = [:]
    private var members: [[HTTPRequestMatchProjection]] = []

    init(matcher: HTTPRequestMatcher) {
        self.matcher = matcher
    }

    mutating func group(for record: SequentialRecord<HTTPInteraction<some Sendable>>,
                        report: (Diagnostic) -> Void) throws -> Int
    {
        let input = matcher.projectOwned(record.value.initialRequest)
        if let group = known[input] {
            return group
        }
        let group: Int
        if let compare = matcher.customComparison {
            do {
                group = try customGroup(for: input, compare: compare)
            } catch {
                report(Diagnostic(issue: .system(DiagnosticLabel("http.correspondence-needs-resolution")),
                                  context: .record(record.identity), recordingImpact: .invalidatesCandidate))
                throw error
            }
        } else {
            group = known.count
        }
        known[input] = group
        return group
    }

    private mutating func customGroup(for input: HTTPRequestMatchProjection,
                                      compare: (HTTPRequestMatchProjection, HTTPRequestMatchProjection) -> Bool)
        throws -> Int
    {
        guard compare(input, input) else { throw HTTPRecordingMergeError.correspondenceNeedsResolution }
        var matched: Int?
        for (index, group) in members.enumerated() {
            var count = 0
            for member in group {
                let forward = compare(input, member)
                guard forward == compare(member, input) else {
                    throw HTTPRecordingMergeError.correspondenceNeedsResolution
                }
                if forward {
                    count += 1
                }
            }
            if count > 0 {
                guard count == group.count, matched == nil else {
                    throw HTTPRecordingMergeError.correspondenceNeedsResolution
                }
                matched = index
            }
        }
        if let matched {
            members[matched].append(input)
            return matched
        }
        members.append([input])
        return members.count - 1
    }
}
