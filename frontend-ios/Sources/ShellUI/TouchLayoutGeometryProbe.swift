import CoreGraphics
import Foundation
#if os(iOS)
import SwiftUI
import UIKit
#endif

/// UIKit measurements for the fullscreen editor's own view hierarchy.
/// Division coordinates have already been checked against the engine's filter.
struct TouchLayoutGeometrySnapshot: Equatable {
    enum HingeStatus: Equatable {
        case unknown
        case closed
        case fullyOpen
        case partiallyOpen
    }

    var bounds: CGRect
    var safeAreaInsets: PadScreen.Insets
    var division: CGRect?
    var hingeStatus: HingeStatus?

    var screen: PadScreen {
        let portrait = bounds.height > bounds.width
        let hingeKnown = hingeStatus.map { $0 != .unknown } ?? false
        let topSafeOnly = portrait && (hingeKnown || division != nil)
        return PadScreen(size: bounds.size, insets: safeAreaInsets,
                         partiallyOpen: hingeStatus == .partiallyOpen,
                         division: division, topSafeOnly: topSafeOnly,
                         customControlsFullBounds: hingeStatus == .closed && !portrait)
    }
}

#if os(iOS)
/// A transparent, non-interactive UIView placed in the editor's full-screen content.
/// UIKit supplies the same view-local bounds, safe areas, fold region, and hinge state
/// that the game root passes to its layout engine.
@MainActor
struct TouchLayoutGeometryProbe: UIViewRepresentable {
    var onChange: (TouchLayoutGeometrySnapshot) -> Void

    func makeUIView(context: Context) -> TouchLayoutGeometryProbeView {
        let view = TouchLayoutGeometryProbeView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: TouchLayoutGeometryProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.setNeedsLayout()
    }
}

@MainActor
final class TouchLayoutGeometryProbeView: UIView {
    var onChange: ((TouchLayoutGeometrySnapshot) -> Void)?
    private var lastSnapshot: TouchLayoutGeometrySnapshot?
    private var hingeStatus: TouchLayoutGeometrySnapshot.HingeStatus?
    private var hingeInteraction: UIInteraction?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        if #available(iOS 27.1, *) {
            installHingeInteraction()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateConstraints() {
        observeReservedRegionChanges()
        super.updateConstraints()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        emitSnapshot()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsUpdateConstraints()
        setNeedsLayout()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    @available(iOS 27.1, *)
    private func installHingeInteraction() {
        let interaction = UIHingeInteraction { [weak self] _, update in
            guard let self else { return }
            self.hingeStatus = Self.status(update.hinge?.status)
            self.setNeedsUpdateConstraints()
            self.setNeedsLayout()
        }
        addInteraction(interaction)
        hingeInteraction = interaction
    }

    @available(iOS 27.1, *)
    private static func status(_ status: UIHinge.Status?) -> TouchLayoutGeometrySnapshot.HingeStatus? {
        guard let status else { return nil }
        return switch status {
        case .unknown: .unknown
        case .closed: .closed
        case .fullyOpen: .fullyOpen
        case .partiallyOpen: .partiallyOpen
        @unknown default: .unknown
        }
    }

    private func observeReservedRegionChanges() {
        if #available(iOS 27.1, *) {
            _ = reservedRegions(kind: .division, options: .includeInactive)
        }
    }

    private func emitSnapshot() {
        let bounds = CGRect(origin: .zero, size: self.bounds.size)
        guard !bounds.isEmpty else { return }
        let safe = safeAreaInsets
        let insets = PadScreen.Insets(top: safe.top, left: safe.left, bottom: safe.bottom, right: safe.right)
        let division: CGRect?
        if #available(iOS 27.1, *) {
            division = reservedRegions(kind: .division, options: .includeInactive)
                .lazy.map(\.frame)
                .compactMap { PadGeo.horizontalDivision(bounds, $0) }
                .first
        } else {
            division = nil
        }
        let snapshot = TouchLayoutGeometrySnapshot(bounds: bounds, safeAreaInsets: insets,
                                                   division: division, hingeStatus: hingeStatus)
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        Task { @MainActor [weak self] in self?.onChange?(snapshot) }
    }
}
#endif
