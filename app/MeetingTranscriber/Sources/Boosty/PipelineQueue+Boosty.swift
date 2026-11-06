import Foundation

extension PipelineQueue {
    func cacheBoostyFallback(
        jobID: UUID,
        cached: [TimestampedSegment]?, // swiftlint:disable:this discouraged_optional_collection
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), let cached else { return }
        jobs[index].boostySegments = cached.filter { !$0.suppressed }.map { segment in
            BoostyExportSegment(
                start: segment.start,
                end: segment.end,
                text: segment.text,
                rawSpeaker: segment.speaker.isEmpty ? "Speaker" : segment.speaker,
                name: segment.speaker,
                track: segment.sourceTrack,
            )
        }
    }

    /// Render raw identities and human names from the SAME diarization topology.
    /// Names are never parsed back from the text transcript or used as IDs.
    func updateBoostySegments(
        jobID: UUID,
        run: DiarizationRun?,
        cachedSegments: [TimestampedSegment]?, // swiftlint:disable:this discouraged_optional_collection
        isDualSource: Bool,
        names: [String: String],
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].boostyCaptureId != nil else { return }
        if let run, let cachedSegments,
           let topology = labelingTopology(run: run, cachedSegments: cachedSegments, isDualSource: isDualSource) {
            let identity = Dictionary((run.combined?.segments ?? []).map { ($0.speaker, $0.speaker) }) { first, _ in first }
            let raw = DiarizationProcess.labelSegments(topology, autoNames: identity)
            let named = DiarizationProcess.labelSegments(topology, autoNames: names)
            jobs[index].boostySegments = zip(raw, named).map { raw, named in
                BoostyExportSegment(
                    start: named.start,
                    end: named.end,
                    text: named.text,
                    rawSpeaker: raw.speaker.isEmpty ? "Speaker" : raw.speaker,
                    name: named.speaker,
                    track: raw.sourceTrack,
                )
            }
        } else if var segments = jobs[index].boostySegments {
            for segment in segments.indices {
                if let name = names[segments[segment].rawSpeaker], !name.isEmpty { segments[segment].name = name }
            }
            jobs[index].boostySegments = segments
        }
        saveSnapshot()
    }
}
