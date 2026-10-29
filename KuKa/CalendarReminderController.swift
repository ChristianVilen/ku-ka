import Foundation

@MainActor
final class CalendarReminderController {
    enum Status: Equatable {
        case off, requestingAccess, ready, calendarAccessRequired, notificationsRequired, readFailed
    }

    private(set) var status: Status = .off
    var onStatusChange: (() -> Void)?

    private let source: CalendarEventSource
    private let notifications: CalendarReminderNotifying
    private let recorder: CalendarReminderRecording
    private let driver: CalendarReminderDriving
    private let settings: Settings
    private let store: CalendarReminderStore
    private let now: () -> Date
    private struct Issued {
        let event: CalendarOccurrence
        let session: UUID?
        var claimed = false
    }
    private struct Association {
        var event: CalendarOccurrence
        let session: UUID
        var continued = false
        var offeredEnd: Date?
    }
    private var issued: [UUID: Issued] = [:]
    private var association: Association?
    private var enabled = false
    private var generation = UUID()
    private var worker: Task<Void, Never>?
    private var refreshRevision = 0
    private var dirty = false

    init(source: CalendarEventSource, notifications: CalendarReminderNotifying,
         recorder: CalendarReminderRecording, driver: CalendarReminderDriving,
         settings: Settings, store: CalendarReminderStore, now: @escaping () -> Date = Date.init) {
        self.source = source
        self.notifications = notifications
        self.recorder = recorder
        self.driver = driver
        self.settings = settings
        self.store = store
        self.now = now
    }

    func setEnabled(_ enabled: Bool) async {
        settings.calendarRecordingRemindersEnabled = enabled
        reset()
        self.enabled = enabled
        guard enabled else { setStatus(.off); return }
        let stamp = generation
        setStatus(.requestingAccess)
        _ = await source.requestAccess()
        guard valid(stamp) else { return }
        guard source.authorization == .full else {
            watch()
            setStatus(.calendarAccessRequired)
            return
        }
        _ = await notifications.requestAccess()
        guard valid(stamp) else { return }
        await activate()
    }

    func resume() async {
        reset()
        enabled = settings.calendarRecordingRemindersEnabled
        guard enabled else { setStatus(.off); return }
        await activate()
    }

    private func activate() async {
        watch()
        guard await accessIsReady(generation) else { return }
        await refresh()
    }

    private func watch() {
        driver.start { [weak self] in
            guard let self else { return }
            Task { await self.refresh() }
        }
    }

    func refresh() async {
        guard enabled else { return }
        refreshRevision += 1
        dirty = true
        if let worker { await worker.value; return }
        let task = Task { [weak self] in
            guard let self else { return }
            while self.dirty && self.enabled {
                self.dirty = false
                await self.reconcile()
            }
            self.worker = nil
        }
        worker = task
        await task.value
    }

    private func reconcile() async {
        let stamp = generation
        guard await accessIsReady(stamp) else { return }
        let revision = refreshRevision
        do {
            let date = now()
            let events = try await source.occurrences(from: date.addingTimeInterval(-120),
                                                      to: date.addingTimeInterval(86_400))
            guard valid(stamp), revision == refreshRevision, await accessIsReady(stamp),
                  revision == refreshRevision else { return }
            var associatedEvent: CalendarOccurrence?
            if let association {
                associatedEvent = try await source.occurrence(id: association.event.id)
                guard valid(stamp), revision == refreshRevision, await accessIsReady(stamp),
                      revision == refreshRevision else { return }
            }
            reconcileRecorder()
            if var link = association {
                if let event = associatedEvent, event.eligible {
                    link.event = event
                    association = link
                } else {
                    association = nil
                }
            }
            let current = now()
            invalidate { item in
                if let session = item.session {
                    return association?.session != session || association?.event != item.event
                        || association?.continued == true || item.event.end > current
                }
                return recorder.activeSessionID != nil || item.event.end <= current
                    || !events.contains(item.event) || !item.event.eligible
            }
            let consumed = store.consumed(at: current)
            let due = events.filter {
                $0.eligible && $0.start <= current && $0.start >= current.addingTimeInterval(-120)
                    && $0.end > current && !consumed.contains($0.id)
            }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
            let canOffer = recorder.activeSessionID == nil && !issued.values.contains { $0.session == nil }
            store.consume(due + events.filter { consumed.contains($0.id) }, at: current)
            if canOffer, let event = due.first {
                await post(event: event, session: nil, stamp: stamp)
            }
            guard valid(stamp), revision == refreshRevision, await accessIsReady(stamp),
                  revision == refreshRevision else { return }
            if let link = association, !link.continued, link.offeredEnd != link.event.end, link.event.end <= now(),
               !issued.values.contains(where: { $0.session == link.session }) {
                association?.offeredEnd = link.event.end
                await post(event: link.event, session: link.session, stamp: stamp)
            }
            guard valid(stamp), revision == refreshRevision else { return }
            let future = events.filter { $0.eligible && $0.start > now() }.map(\.start)
            let end = association.flatMap { !$0.continued && $0.event.end > now() ? $0.event.end : nil }
            let offerEnd = issued.values.filter { $0.session == nil }.map { $0.event.end }
            driver.schedule(at: (future + offerEnd + [end].compactMap { $0 }).min())
            setStatus(.ready)
        } catch {
            guard valid(stamp), revision == refreshRevision else { return }
            invalidate { _ in true }
            driver.schedule(at: nil)
            setStatus(.readFailed)
        }
    }

    private func post(event: CalendarOccurrence, session: UUID?, stamp: UUID) async {
        let token = UUID()
        issued[token] = Issued(event: event, session: session)
        do {
            try await notifications.add(CalendarReminder(token: token, kind: session == nil ? .start : .end,
                                                         title: event.displayTitle))
            if !valid(stamp) || issued[token] == nil {
                notifications.remove(tokens: [token])
            }
        } catch {
            issued.removeValue(forKey: token)
            notifications.remove(tokens: [token])
        }
    }

    func recorderDidChange() {
        reconcileRecorder()
        guard enabled else { return }
        Task { await self.refresh() }
    }

    private func reconcileRecorder() {
        if association?.session != recorder.activeSessionID { association = nil }
        invalidate { item in
            item.session.map { $0 != recorder.activeSessionID } ?? (recorder.activeSessionID != nil)
        }
    }

    func shutDown() {
        enabled = false
        reset()
        setStatus(.off)
    }

    private func reset() {
        generation = UUID()
        refreshRevision += 1
        dirty = false
        association = nil
        invalidate { _ in true }
        driver.stop()
    }

    private func valid(_ stamp: UUID) -> Bool { enabled && generation == stamp }

    private func accessIsReady(_ stamp: UUID) async -> Bool {
        guard valid(stamp) else { return false }
        if source.authorization != .full {
            accessRequired(.calendarAccessRequired)
            return false
        }
        let granted = await notifications.authorizationGranted()
        guard valid(stamp) else { return false }
        if source.authorization != .full {
            accessRequired(.calendarAccessRequired)
            return false
        }
        if !granted {
            accessRequired(.notificationsRequired)
            return false
        }
        return true
    }

    private func accessRequired(_ status: Status) {
        generation = UUID()
        association = nil
        invalidate { _ in true }
        driver.schedule(at: nil)
        setStatus(status)
    }

    private func setStatus(_ value: Status) {
        guard status != value else { return }
        status = value
        onStatusChange?()
    }

    private func invalidate(where predicate: (Issued) -> Bool) {
        let tokens = issued.filter { predicate($0.value) }.map(\.key)
        for token in tokens { issued.removeValue(forKey: token) }
        if !tokens.isEmpty { notifications.remove(tokens: tokens) }
    }

    func handle(_ action: CalendarReminderAction, token: UUID) async {
        let stamp = generation
        guard enabled, var item = issued[token], !item.claimed else { return }
        item.claimed = true
        issued[token] = item
        notifications.remove(tokens: [token])
        guard await accessIsReady(stamp), issued[token] != nil else { return }
        do {
            let event = try await source.occurrence(id: item.event.id)
            guard valid(stamp), await accessIsReady(stamp), issued[token] != nil else { return }
            issued.removeValue(forKey: token)
            guard event == item.event, item.event.eligible else { return }
            if let session = item.session {
                guard association?.session == session, recorder.activeSessionID == session,
                      item.event.end <= now(), association?.continued == false else { return }
                switch action {
                case .stop: recorder.stopRecording(ifSession: session); reconcileRecorder()
                case .continueRecording: association?.continued = true
                case .showControls: recorder.showControls()
                default: break
                }
            } else {
                guard action == .start, item.event.start <= now(), item.event.end > now(),
                      recorder.activeSessionID == nil else { return }
                let session = await recorder.startRecording(title: item.event.displayTitle)
                guard valid(stamp), await accessIsReady(stamp), let session,
                      recorder.activeSessionID == session else { return }
                let revision = refreshRevision
                let current = try await source.occurrence(id: item.event.id)
                guard valid(stamp), await accessIsReady(stamp), recorder.activeSessionID == session,
                      revision == refreshRevision, current == item.event else { return }
                association = Association(event: item.event, session: session)
                await refresh()
            }
        } catch {
            guard valid(stamp) else { return }
            invalidate { _ in true }
            setStatus(.readFailed)
        }
    }
}
