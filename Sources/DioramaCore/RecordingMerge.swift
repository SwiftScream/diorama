/// A system-owned merge of a validated baseline and a fresh prepared recording.
///
/// Inputs belong to the same typed track. The callback runs once during normal
/// record-mode finalization, after capture freezes and outside lease state locks.
/// It must be deterministic, use only prepared stable content, and validate its
/// domain's complete result. It must not read live sources or wait for finish.
/// Core preserves the track identity and validates the returned header and values
/// without repeating capture transformations. Failure invalidates the candidate.
/// Replay, passthrough, unhealthy capture, and startup rollback never invoke it.
public typealias RecordingMerge<Value: Sendable, Header: Sendable> = @Sendable (
    SequentialTrack<Value, Header>, SequentialTrack<Value, Header>) throws -> SequentialTrack<Value, Header>

struct FinalRecordingMerge<Value: Sendable, Header: Sendable>: Sendable {
    let merge: RecordingMerge<Value, Header>
    let valuePreparation: ValuePreparation<Value>
    let headerPreparation: ValuePreparation<Header>

    func apply(
        baseline: SequentialTrack<Value, Header>,
        recording: SequentialTrack<Value, Header>,
        reporter: DiagnosticReporter) -> SequentialTrack<Value, Header>?
    {
        let merged: SequentialTrack<Value, Header>
        do {
            merged = try merge(baseline, recording)
        } catch {
            reportFailure(for: recording.id, reporter: reporter)
            return nil
        }
        guard merged.id == recording.id else {
            reportFailure(for: recording.id, reporter: reporter)
            return nil
        }
        do {
            let header = try headerPreparation.validateRecording(
                merged.header, reporter: reporter, context: .track(merged.id))
            let values = try merged.records.map { record throws(PreparationFailure) in
                try valuePreparation.validateRecording(
                    record.value, reporter: reporter, context: .record(record.identity))
            }
            return SequentialTrack(id: merged.id, header: header, values: values)
        } catch {
            // Validation retains safe evidence and health before returning failure.
            return nil
        }
    }

    private func reportFailure(for id: TrackID, reporter: DiagnosticReporter) {
        reporter.record(Diagnostic(issue: .verification(.recordingMergeFailed),
                                   context: .track(id), recordingImpact: .invalidatesCandidate))
    }
}

/// Transfers callback ownership out of the lease lock even when it must not run.
enum RecordingMergeFinalization<Value: Sendable, Header: Sendable> {
    case apply(FinalRecordingMerge<Value, Header>,
               baseline: SequentialTrack<Value, Header>, recording: SequentialTrack<Value, Header>)
    case discard(FinalRecordingMerge<Value, Header>)
}
