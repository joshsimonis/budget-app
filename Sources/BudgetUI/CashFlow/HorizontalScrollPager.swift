import AppKit

/// Turns sideways trackpad swipes (or a sideways scroll wheel) into one-column steps.
final class HorizontalScrollPager {
    private var monitor: Any?
    private var accumulated: CGFloat = 0

    func start(onStep: @escaping (Int) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            // Leave vertical scrolling alone.
            guard abs(dx) > abs(dy) * 1.5, abs(dx) > 0 else { return event }
            // Momentum after lifting the fingers would page too far.
            if event.momentumPhase != [] { return nil }
            if event.phase == .began { self.accumulated = 0 }
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 45 : 1
            self.accumulated += dx
            while abs(self.accumulated) >= threshold {
                onStep(self.accumulated > 0 ? -1 : 1)
                self.accumulated += self.accumulated > 0 ? -threshold : threshold
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        accumulated = 0
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
