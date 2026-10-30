import Foundation

struct RecordedMeeting {
    let folder: MeetingFolder
    let speakers: TeamsSpeakerEvidence
}

@MainActor
final class TeamsSpeakerRecording {
    private let observer: any TeamsSpeakerObserving
    private var history = TeamsSpeakerHistory()
    private var task: Task<Void, Never>?
    private var runID: UUID?
    private var ended = false

    init(observer: any TeamsSpeakerObserving) { self.observer = observer }

    isolated deinit { task?.cancel() }

    func resume(at lowerBound: HostTime) {
        guard !ended, runID == nil else { return }
        let id = UUID()
        runID = id
        let observations = observer.observations()
        task = Task { [weak self] in
            for await sample in observations {
                guard !Task.isCancelled, let self, self.runID == id else { break }
                guard sample.began >= lowerBound else { continue }
                if !self.history.append(sample, runID: id) {
                    self.ended = true
                    self.pause()
                    break
                }
            }
        }
    }

    func pause() {
        runID = nil
        task?.cancel()
        task = nil
    }

    func finish(clock: RecordingClock, endingAt: HostTime) -> TeamsSpeakerEvidence {
        pause()
        ended = true
        return history.finish(clock: clock, endingAt: endingAt)
    }
}
