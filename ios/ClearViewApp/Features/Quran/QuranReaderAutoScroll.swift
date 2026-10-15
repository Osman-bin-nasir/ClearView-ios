import SwiftUI
import UIKit
import Observation

/// Drives the existing native List, preserving its ability to restore distant
/// ayahs without estimating the height of Arabic text that is not laid out yet.
@MainActor
@Observable
final class QuranReaderAutoScroll: NSObject, UIGestureRecognizerDelegate {
    private(set) var isRunning = false
    var speed: QuranAutoScrollSpeed = .medium

    @ObservationIgnored private weak var scrollView: UIScrollView?
    @ObservationIgnored private var touchObserver: UITapGestureRecognizer?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastFrame: CFTimeInterval?
    @ObservationIgnored private var targetOffset: Double?

    func attach(_ scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        let observer = UITapGestureRecognizer()
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false
        observer.delegate = self
        scrollView.addGestureRecognizer(observer)
        touchObserver = observer
    }

    func detach() {
        pause()
        if let touchObserver { scrollView?.removeGestureRecognizer(touchObserver) }
        touchObserver = nil
        scrollView = nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Observe touch-down, including a tap on blank space, then decline the
        // gesture so verse buttons, selection, and manual scrolling still work.
        pause()
        return false
    }

    func start() {
        guard let scrollView, !isRunning else { return }
        isRunning = true
        lastFrame = nil
        targetOffset = Double(scrollView.contentOffset.y)
        let link = CADisplayLink(target: self, selector: #selector(advance(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func pause() {
        displayLink?.invalidate()
        displayLink = nil
        lastFrame = nil
        targetOffset = nil
        isRunning = false
    }

    @objc private func advance(_ link: CADisplayLink) {
        guard let scrollView, scrollView.window != nil else { pause(); return }
        guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else {
            pause()
            return
        }
        let previous = lastFrame ?? link.timestamp
        lastFrame = link.timestamp
        let minimum = -scrollView.adjustedContentInset.top
        let maximum = max(minimum, scrollView.contentSize.height - scrollView.bounds.height
                          + scrollView.adjustedContentInset.bottom)
        // Retain fractional movement at slow speeds on high-refresh displays.
        // UIKit may align the presented offset to a physical pixel.
        let actual = Double(scrollView.contentOffset.y)
        let current = targetOffset.flatMap { abs($0 - actual) <= 2 ? $0 : nil } ?? actual
        let next = QuranScrollMotion.nextOffset(
            current: current, minimum: minimum, maximum: maximum,
            elapsed: link.timestamp - previous, speed: speed
        )
        targetOffset = next
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: next), animated: false)
        if next >= maximum { pause() }
    }
}

/// A non-interactive probe beside the List connects its native scroll view to
/// the display-link driver. It does not replace the List's delegate or gestures.
struct QuranReaderScrollConnection: UIViewRepresentable {
    let driver: QuranReaderAutoScroll

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.driver = driver
        return view
    }

    func updateUIView(_ uiView: Probe, context: Context) { uiView.connect() }

    static func dismantleUIView(_ uiView: Probe, coordinator: ()) { uiView.driver?.detach() }

    final class Probe: UIView {
        weak var driver: QuranReaderAutoScroll?
        private var connectionScheduled = false

        override func layoutSubviews() {
            super.layoutSubviews()
            connect()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            connect()
        }

        func connect() {
            guard !connectionScheduled else { return }
            connectionScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.connectionScheduled = false
                guard self.window != nil else { return }
                // The overlay and List are siblings. Search the nearest common
                // container first so another tab's list cannot take precedence.
                var ancestor = self.superview
                while let container = ancestor {
                    if let scrollView = self.findList(in: container) {
                        self.driver?.attach(scrollView)
                        return
                    }
                    ancestor = container.superview
                }
            }
        }

        private func findList(in view: UIView) -> UIScrollView? {
            guard view !== self, !view.isHidden, view.alpha > 0 else { return nil }
            if let scroll = view as? UIScrollView,
               scroll is UICollectionView || scroll is UITableView,
               let window = scroll.window,
               scroll.convert(scroll.bounds, to: window).intersects(window.bounds) {
                return scroll
            }
            for child in view.subviews {
                if let scroll = findList(in: child) { return scroll }
            }
            return nil
        }
    }
}
