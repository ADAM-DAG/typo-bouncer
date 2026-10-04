import AppKit
import SwiftUI
import QuartzCore

/// Feedback for shortcut-triggered Auto. No text from the selection is displayed.
enum CorrectionStatus: Equatable {
    case correcting, applying, applied, unchanged, review, failed, noText
    var busy: Bool { self == .correcting || self == .applying }
    var needsDetails: Bool { self == .review || self == .failed || self == .noText }
    var title: String {
        switch self {
        case .correcting: String(localized: "Tidying up…")
        case .applying: String(localized: "Applying…")
        case .applied: String(localized: "All tidied up")
        case .unchanged: String(localized: "Looks good already")
        case .review: String(localized: "A quick review")
        case .failed: String(localized: "Couldn't correct")
        case .noText: String(localized: "No text selected")
        }
    }
    var completed: Bool { self == .applied || self == .unchanged }

}

enum ReviewKeyAction { case apply, collapse }

final class StatusPanel: NSPanel {
    var allowsReviewFocus = false {
        didSet { if !allowsReviewFocus { pendingReviewKey = nil } }
    }
    private var pendingReviewKey: (code: UInt16, action: ReviewKeyAction)?
    var reviewKeyAction: ((ReviewKeyAction) -> Void)?
    var reviewFocusLost: (() -> Void)?
    override var canBecomeKey: Bool { allowsReviewFocus }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        pendingReviewKey = nil
        super.resignKey()
        if allowsReviewFocus { reviewFocusLost?() }
    }

    static func action(for event: NSEvent, expanded: Bool, focused: Bool) -> ReviewKeyAction? {
        guard expanded, focused, event.type == .keyDown, !event.isARepeat,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return nil }
        switch event.keyCode {
        case 36, 76: return .apply // Return and keypad Enter, only in this window.
        case 53: return .collapse
        default: return nil
        }
    }
    /// Commit on release, keeping this window focused through all held-key repeats.
    /// Otherwise a repeat could reach Send after the initial key-down closed review.
    func consumeReviewKey(_ event: NSEvent, focused: Bool) -> Bool {
        guard allowsReviewFocus, focused else { return false }
        if let pendingReviewKey, event.keyCode == pendingReviewKey.code {
            if event.type == .keyUp {
                self.pendingReviewKey = nil
                reviewKeyAction?(pendingReviewKey.action)
                return true
            }
            if event.type == .keyDown { return true }
        }
        if let action = Self.action(for: event, expanded: true, focused: true) {
            pendingReviewKey = (event.keyCode, action)
            return true
        }
        // Never forward a held bare Return to a default button while reviewing.
        return (event.type == .keyUp || (event.type == .keyDown && event.isARepeat))
            && [UInt16(36), 76, 53].contains(event.keyCode)
            && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
    }
    override func sendEvent(_ event: NSEvent) {
        if consumeReviewKey(event, focused: isKeyWindow) { return }
        super.sendEvent(event)
    }
}

/// A compact island of feedback. Its canvas stays fixed while the capsule eases
/// between states, so neither the input nor the panel jumps as its contents change.
@MainActor
final class StatusPillView: NSView {
    static let canvasSize = NSSize(width: 240, height: 58)
    static let shapeDuration = 0.42
    static let collapseDuration = 0.34
    static let loadingColor = NSColor(srgbRed: 1, green: 159.0 / 255, blue: 11.0 / 255, alpha: 1)
    private static let completedColor = NSColor(srgbRed: 48.0 / 255, green: 209.0 / 255, blue: 88.0 / 255, alpha: 1)
    private static let progressTimeScale = 1.1
    private static let progressDuration = 20.0
    private static let workingStroke: CGFloat = 3.25
    private static let completedStroke: CGFloat = 2.25
    // Reserve a visible gap until a successful result is confirmed.
    private static let workingLimit: CGFloat = 0.90
    private var progressStartedAt: CFTimeInterval?
    private var progressBaseline: CGFloat = 0
    let capsule = CAGradientLayer()
    let track = CAShapeLayer()
    let arc = CAShapeLayer()
    let glyph = CAShapeLayer()
    private let indicator = CALayer()
    private let content = CALayer()
    private let reviewClip = NSView()
    let reviewMask = CAShapeLayer()
    private var reviewView: NSView?
    private var compactCenter: CGPoint?
    private var expanded = false
    private var contractingFrame: NSRect?
    private var status: CorrectionStatus?
    private var reduceMotion = false
    private var visible = false
    private var hovered = false
    private var pointerTracking: NSTrackingArea?
    private let details: () -> Void

    init(details: @escaping () -> Void) {
        self.details = details
        super.init(frame: NSRect(origin: .zero, size: Self.canvasSize))
        wantsLayer = true
        layer?.opacity = 0
        capsule.colors = [NSColor(srgbRed: 0.075, green: 0.078, blue: 0.085, alpha: 1).cgColor,
                          NSColor(srgbRed: 0.115, green: 0.12, blue: 0.13, alpha: 1).cgColor,
                          NSColor(srgbRed: 0.16, green: 0.165, blue: 0.18, alpha: 1).cgColor]
        capsule.locations = [0, 0.55, 1]
        capsule.startPoint = CGPoint(x: 0.5, y: 0); capsule.endPoint = CGPoint(x: 0.5, y: 1)
        capsule.cornerRadius = 19; capsule.cornerCurve = .continuous
        capsule.borderWidth = 0.5
        capsule.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        capsule.masksToBounds = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.16; layer?.shadowRadius = 5.5
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(capsule); layer?.addSublayer(content)
        content.addSublayer(track); content.addSublayer(indicator)
        indicator.addSublayer(arc); content.addSublayer(glyph)
        for shape in [track, arc, glyph] {
            shape.fillColor = nil; shape.lineWidth = 1.6
            shape.lineCap = .round; shape.lineJoin = .round
        }
        track.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        track.lineWidth = 1.75; arc.lineWidth = Self.workingStroke
        arc.strokeEnd = 0
        glyph.strokeEnd = 0; glyph.lineWidth = 2.1
        reviewClip.wantsLayer = true
        reviewClip.layer?.mask = reviewMask; reviewClip.isHidden = true
        addSubview(reviewClip)
        setAccessibilityElement(true)
        layout()
    }
    required init?(coder: NSCoder) { nil }
    // Focus is acquired while still compact, before the review starts to open.
    override var acceptsFirstResponder: Bool { true }

    private let targetWidth: CGFloat = 48

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let scale = window?.backingScaleFactor ?? 2
        for item in [layer, capsule, content, track, indicator, arc, glyph, reviewMask, reviewClip.layer].compactMap({ $0 }) { item.contentsScale = scale }
        let width = targetWidth
        if expanded {
            capsule.frame = bounds.insetBy(dx: 10, dy: 10)
        } else {
            capsule.bounds = CGRect(x: 0, y: 0, width: width, height: 38)
            let destination = contractingFrame ?? bounds
            capsule.position = CGPoint(x: destination.midX, y: destination.midY)
        }
        capsule.cornerRadius = expanded ? 24 : 19
        // Keep the compact indicator anchored to its destination. Parenting it to
        // the resizing capsule makes it slide across the panel during a morph.
        let center = expanded ? compactCenter ?? capsule.position : capsule.position
        content.frame = CGRect(x: center.x - width / 2, y: center.y - 19, width: width, height: 38)
        if let reviewView {
            if expanded {
                reviewClip.frame = capsule.frame
                reviewView.frame = reviewClip.bounds.insetBy(dx: 18, dy: 18)
                reviewMask.frame = reviewClip.bounds
                reviewMask.path = Self.reviewPath(reviewClip.bounds, corner: 24)
            }
        }
        let icon = CGRect(x: (width - 26) / 2, y: 6, width: 26, height: 26)
        track.frame = icon; indicator.frame = icon
        arc.frame = indicator.bounds; glyph.frame = icon
        // AppKit layer coordinates point up: 12 o'clock, advancing clockwise.
        let circle = CGMutablePath()
        circle.addArc(center: CGPoint(x: 13, y: 13), radius: 11,
                      startAngle: .pi / 2, endAngle: -.pi * 3 / 2, clockwise: true)
        track.path = circle; arc.path = circle
        let mark = CGMutablePath()
        if status?.completed == true {
            mark.move(to: CGPoint(x: 8.25, y: 13)); mark.addLine(to: CGPoint(x: 11.75, y: 9.5)); mark.addLine(to: CGPoint(x: 17.75, y: 16.25))
        } else if status?.needsDetails == true {
            mark.move(to: CGPoint(x: 13, y: 17)); mark.addLine(to: CGPoint(x: 13, y: 12))
            mark.move(to: CGPoint(x: 13, y: 8)); mark.addLine(to: CGPoint(x: 13, y: 8.2))
        }
        glyph.path = mark
        CATransaction.commit()
        updateTrackingAreas()
    }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); needsLayout = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); colors(animated: false) }

    private func morph(_ key: String, from: Any, to: Any, on item: CALayer, name: String, duration: Double, delay: Double = 0) {
        guard !reduceMotion else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from; animation.toValue = to; animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.24, 0.72, 0.22, 1)
        if delay > 0 { animation.beginTime = item.convertTime(CACurrentMediaTime(), from: nil) + delay; animation.fillMode = .backwards }
        item.add(animation, forKey: name)
    }
    private static func reviewPath(_ frame: CGRect, corner: CGFloat) -> CGPath {
        CGPath(roundedRect: frame, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }
    private func animate(_ key: String, from: Any, to: Any, duration: Double,
                         on item: CALayer, name: String, delay: Double = 0) {
        guard !reduceMotion else { return }
        let animation = CABasicAnimation(keyPath: key)
        animation.fromValue = from; animation.toValue = to; animation.duration = duration
        animation.timingFunction = ["opacity", "strokeColor", "lineWidth", "strokeEnd"].contains(key) ? CAMediaTimingFunction(name: .easeInEaseOut)
            : CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        if delay > 0 { animation.beginTime = item.convertTime(CACurrentMediaTime(), from: nil) + delay; animation.fillMode = .backwards }
        item.add(animation, forKey: name)
    }
    private func colors(animated: Bool, completionDelay: Double = 0) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = (status?.completed == true ? Self.completedColor : Self.loadingColor).cgColor
            let old = arc.presentation()?.strokeColor ?? arc.strokeColor
            CATransaction.begin(); CATransaction.setDisableActions(true)
            arc.strokeColor = color; glyph.strokeColor = color
            CATransaction.commit()
            if animated, let old {
                animate("strokeColor", from: old, to: color, duration: 0.38, on: arc, name: "color", delay: completionDelay)
            }
        }
    }

    private func estimatedFraction(at elapsed: Double) -> Double {
        let t = max(0, min(Self.progressDuration, elapsed)), timeScale = Self.progressTimeScale
        let normalization = 1 - (1 + Self.progressDuration / timeScale) * exp(-Self.progressDuration / timeScale)
        return (1 - (1 + t / timeScale) * exp(-t / timeScale)) / normalization
    }

    private var progressMotion: (velocity: CGFloat, acceleration: CGFloat) {
        guard let progressStartedAt else { return (0, 0) }
        let elapsed = max(0, CACurrentMediaTime() - progressStartedAt), timeScale = Self.progressTimeScale
        guard elapsed < Self.progressDuration else { return (0, 0) }
        let normalization = 1 - (1 + Self.progressDuration / timeScale) * exp(-Self.progressDuration / timeScale)
        let factor = (Self.workingLimit - progressBaseline) * CGFloat(exp(-elapsed / timeScale) / (timeScale * timeScale * normalization))
        return (factor * elapsed, factor * (1 - elapsed / timeScale))
    }

    private func closeRing(from start: CGFloat, motion: (velocity: CGFloat, acceleration: CGFloat), duration: Double) {
        let remaining = max(0, 1 - start)
        let velocity = remaining > 0 ? motion.velocity * duration / remaining : 0
        let acceleration = remaining > 0 ? motion.acceleration * duration * duration / remaining : 0
        let completion = CAKeyframeAnimation(keyPath: "strokeEnd")
        // Preserve both velocity and acceleration at handoff. The quintic curve
        // comes to rest at 12 o'clock without the sudden surge of a new ease curve.
        completion.values = (0...120).map { index in
            let t = CGFloat(index) / 120, t2 = t * t, t3 = t2 * t, t4 = t3 * t, t5 = t4 * t
            let fraction = velocity * t + acceleration / 2 * t2
                + (10 - 6 * velocity - 1.5 * acceleration) * t3
                + (-15 + 8 * velocity + 1.5 * acceleration) * t4
                + (6 - 3 * velocity - 0.5 * acceleration) * t5
            return start + remaining * fraction
        }
        completion.keyTimes = (0...120).map { NSNumber(value: Double($0) / 120) }
        completion.duration = duration; completion.calculationMode = .linear
        arc.add(completion, forKey: "completion")
    }

    func update(_ next: CorrectionStatus, reduceMotion: Bool) {
        guard next != status || self.reduceMotion != reduceMotion else { return }
        let previous = status, motionChanged = self.reduceMotion != reduceMotion
        let oldEnd = arc.presentation()?.strokeEnd ?? arc.strokeEnd
        let motion = progressMotion
        let oldWidth = arc.presentation()?.lineWidth ?? arc.lineWidth
        let oldTrackOpacity = track.presentation()?.opacity ?? track.opacity
        status = next; self.reduceMotion = reduceMotion
        if next != .noText { layer?.removeAnimation(forKey: "emptySelectionShake") }
        setAccessibilityLabel(next.title)
        setAccessibilityRole(next.needsDetails ? .button : .progressIndicator)
        toolTip = next.needsDetails ? next.title : nil
        if motionChanged && reduceMotion {
            removeAnimations()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            capsule.transform = CATransform3DIdentity; content.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        layout()
        // Applying continues the same timeline: no restart, speed jump or width change.
        if previous?.busy == true && next.busy && !motionChanged { return }
        let finishing = next.completed && previous?.busy == true
        // A short remaining arc settles sooner; a quick result gets enough time
        // to travel the entire circle rather than snapping straight to success.
        let completionDelay = finishing && !reduceMotion ? 0.58 + 0.28 * Double(1 - oldEnd) : 0
        colors(animated: previous != nil && !reduceMotion, completionDelay: completionDelay)
        arc.removeAnimation(forKey: "progress"); arc.removeAnimation(forKey: "completion")
        arc.removeAnimation(forKey: "weight"); track.removeAllAnimations(); glyph.removeAllAnimations()
        let start = previous?.busy == true ? min(oldEnd, Self.workingLimit) : next == .applying ? 0.86 : 0
        CATransaction.begin(); CATransaction.setDisableActions(true)
        arc.strokeEnd = next.busy ? (reduceMotion ? max(start, next == .correcting ? 0.12 : Self.workingLimit) : Self.workingLimit) : 1
        glyph.strokeEnd = next.busy ? 0 : 1
        arc.lineWidth = next.completed ? Self.completedStroke : Self.workingStroke
        track.opacity = next.completed ? 0 : 1
        glyph.transform = CATransform3DIdentity
        CATransaction.commit()
        if previous != nil {
            animate("lineWidth", from: oldWidth, to: arc.lineWidth, duration: 0.38, on: arc, name: "weight", delay: completionDelay)
            animate("opacity", from: oldTrackOpacity, to: track.opacity, duration: 0.38, on: track, name: "visibility", delay: completionDelay)
        }
        if next.busy && !reduceMotion {
            progressStartedAt = CACurrentMediaTime(); progressBaseline = start
            let progress = CAKeyframeAnimation(keyPath: "strokeEnd")
            // Estimated progress accelerates gently, then slows before a visible gap.
            progress.values = (0...600).map { index in
                start + (Self.workingLimit - start) * CGFloat(estimatedFraction(at: Double(index) / 600 * Self.progressDuration))
            }
            progress.keyTimes = (0...600).map { NSNumber(value: Double($0) / 600) }
            progress.duration = Self.progressDuration; progress.calculationMode = .linear
            arc.add(progress, forKey: "progress")
        } else {
            progressStartedAt = nil
            if finishing && !reduceMotion {
                closeRing(from: oldEnd, motion: motion, duration: completionDelay)
                animate("strokeEnd", from: 0, to: 1, duration: 0.28, on: glyph, name: "check", delay: completionDelay + 0.16)
                animate("transform.scale", from: 0.92, to: 1, duration: 0.34, on: glyph, name: "settle", delay: completionDelay + 0.16)
            } else if next.needsDetails && !reduceMotion {
                animate("strokeEnd", from: oldEnd, to: 1, duration: 0.24, on: arc, name: "completion")
            }
        }
        if !next.needsDetails {
            hovered = false
            capsule.removeAnimation(forKey: "interaction")
            CATransaction.begin(); CATransaction.setDisableActions(true)
            capsule.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    func setVisible(_ show: Bool) {
        guard show != visible else { return }
        let wasFading = layer?.animation(forKey: "visibility") != nil
        let opacity = layer?.presentation()?.opacity ?? layer?.opacity ?? 0
        let scale = capsule.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        visible = show
        capsule.removeAnimation(forKey: "exit")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.opacity = show ? 1 : 0
        capsule.transform = CATransform3DIdentity
        CATransaction.commit()
        if let layer { animate("opacity", from: opacity, to: show ? 1 : 0, duration: 0.18, on: layer, name: "visibility") }
        if show && !expanded {
            animate("transform.scale", from: wasFading ? scale : 0.96, to: 1, duration: 0.22, on: capsule, name: "entrance")
            animate("opacity", from: wasFading ? content.presentation()?.opacity ?? content.opacity : 0,
                    to: 1, duration: 0.18, on: content, name: "reveal")
        } else if !show {
            animate("transform.scale", from: scale, to: 0.98, duration: 0.18, on: capsule, name: "exit")
        }
    }

    func shake() {
        guard visible, !expanded, status == .noText, !reduceMotion, let layer else { return }
        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        // A smooth start and finish with three diminishing oscillations. Moving the
        // shared layer keeps the capsule, ring and shadow together; layout stays put.
        shake.values = (0...90).map { index in
            let t = Double(index) / 90
            return -11 * sin(6 * .pi * t) * sin(.pi * t) * exp(-3 * t)
        }
        shake.keyTimes = (0...90).map { NSNumber(value: Double($0) / 90) }
        shake.duration = 0.46; shake.calculationMode = .linear; shake.isAdditive = true
        shake.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) + 0.12
        layer.add(shake, forKey: "emptySelectionShake")
    }
    private func removeAnimations() {
        for item in [layer, capsule, content, track, indicator, arc, glyph, reviewMask, reviewClip.layer, reviewView?.layer].compactMap({ $0 }) { item.removeAllAnimations() }
    }
    func reset() {
        visible = false; status = nil; hovered = false; progressStartedAt = nil; progressBaseline = 0
        finishContraction()
        removeAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.opacity = 0; capsule.transform = CATransform3DIdentity; content.transform = CATransform3DIdentity
        arc.strokeEnd = 0; arc.lineWidth = Self.workingStroke; track.opacity = 1
        glyph.strokeEnd = 0; glyph.transform = CATransform3DIdentity
        CATransaction.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        pointerTracking = nil
        if status?.needsDetails == true && !expanded && contractingFrame == nil {
            let tracking = NSTrackingArea(rect: capsule.frame, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
            addTrackingArea(tracking); pointerTracking = tracking
        }
    }
    private func react(to scale: CGFloat) {
        guard !reduceMotion else { return }
        let old = capsule.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        capsule.transform = CATransform3DMakeScale(scale, scale, 1)
        CATransaction.commit()
        animate("transform.scale", from: old, to: scale, duration: 0.16, on: capsule, name: "interaction")
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; react(to: 1.012) }
    override func mouseExited(with event: NSEvent) { hovered = false; react(to: 1) }
    override func mouseDown(with event: NSEvent) { if status?.needsDetails == true { react(to: 0.985) } }
    override func mouseUp(with event: NSEvent) {
        guard status?.needsDetails == true, !expanded, contractingFrame == nil else { return }
        react(to: hovered ? 1.012 : 1)
        if capsule.frame.contains(convert(event.locationInWindow, from: nil)) { details() }
    }
    func expand(with view: NSView, from oldBounds: CGRect, position oldPosition: CGPoint, cornerRadius oldCorner: CGFloat = 19) {
        layer?.removeAnimation(forKey: "emptySelectionShake")
        contractingFrame = nil; expanded = true; compactCenter = oldPosition
        // A details click may race the compact pill's fade-out. Expansion must
        // restore the parent opacity as well as reveal the review content.
        setVisible(true)
        if reviewView !== view {
            reviewView?.removeFromSuperview(); reviewView = view
            view.wantsLayer = true; reviewClip.addSubview(view)
        }
        setAccessibilityElement(false)
        reviewClip.isHidden = false
        let oldContentOpacity = content.presentation()?.opacity ?? content.opacity
        // Entry, hover and the compact reveal must never compete with expansion.
        capsule.removeAllAnimations(); content.removeAllAnimations(); reviewMask.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        capsule.transform = CATransform3DIdentity
        content.opacity = 0; reviewClip.layer?.opacity = 1
        CATransaction.commit()
        layout()
        view.layoutSubtreeIfNeeded()
        animate("opacity", from: oldContentOpacity, to: 0, duration: 0.08, on: content, name: "reveal")
        morph("bounds", from: NSValue(rect: oldBounds), to: NSValue(rect: capsule.bounds), on: capsule, name: "islandShape", duration: Self.shapeDuration)
        morph("position", from: NSValue(point: oldPosition), to: NSValue(point: capsule.position), on: capsule, name: "islandPosition", duration: Self.shapeDuration)
        morph("cornerRadius", from: oldCorner, to: 24, on: capsule, name: "islandCorner", duration: Self.shapeDuration)
        let oldFrame = CGRect(x: oldPosition.x - oldBounds.width / 2 - reviewClip.frame.minX,
                              y: oldPosition.y - oldBounds.height / 2 - reviewClip.frame.minY,
                              width: oldBounds.width, height: oldBounds.height)
        morph("path", from: Self.reviewPath(oldFrame, corner: oldCorner), to: reviewMask.path!,
              on: reviewMask, name: "islandMask", duration: Self.shapeDuration)
        if let clip = reviewClip.layer {
            // Text is laid out once at its final size. Only its mask and opacity
            // change, avoiding a squeezed or sliding page of text.
            clip.removeAllAnimations()
            animate("opacity", from: 0, to: 1, duration: 0.22, on: clip, name: "reveal", delay: 0.14)
        }
    }
    func contract(to destination: NSRect) {
        let oldBounds = capsule.presentation()?.bounds ?? capsule.bounds
        let oldPosition = capsule.presentation()?.position ?? capsule.position
        let oldCorner = capsule.presentation()?.cornerRadius ?? capsule.cornerRadius
        let oldMask = reviewMask.presentation()?.path ?? reviewMask.path
        let oldReviewOpacity = reviewClip.layer?.presentation()?.opacity ?? reviewClip.layer?.opacity ?? 1
        let oldContentOpacity = content.presentation()?.opacity ?? content.opacity
        expanded = false; contractingFrame = destination
        setAccessibilityElement(true)
        capsule.removeAllAnimations(); content.removeAllAnimations(); reviewMask.removeAllAnimations()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        capsule.transform = CATransform3DIdentity
        content.opacity = 1; reviewClip.layer?.opacity = 0
        CATransaction.commit()
        layout()
        // Let the page fade before the edges close over it. The complete transition
        // still ends together, including the anchored compact indicator's reveal.
        let shapeDelay = 0.06, duration = Self.collapseDuration - shapeDelay
        morph("bounds", from: NSValue(rect: oldBounds), to: NSValue(rect: capsule.bounds), on: capsule, name: "islandShape", duration: duration, delay: shapeDelay)
        morph("position", from: NSValue(point: oldPosition), to: NSValue(point: capsule.position), on: capsule, name: "islandPosition", duration: duration, delay: shapeDelay)
        morph("cornerRadius", from: oldCorner, to: 19, on: capsule, name: "islandCorner", duration: duration, delay: shapeDelay)
        animate("opacity", from: oldContentOpacity, to: 1, duration: 0.14, on: content, name: "reveal", delay: 0.20)
        let destinationMask = Self.reviewPath(capsule.frame.offsetBy(dx: -reviewClip.frame.minX, dy: -reviewClip.frame.minY), corner: 19)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        reviewMask.path = destinationMask
        CATransaction.commit()
        if let oldMask {
            morph("path", from: oldMask, to: destinationMask, on: reviewMask, name: "islandMask", duration: duration, delay: shapeDelay)
        }
        if let clip = reviewClip.layer {
            clip.removeAllAnimations()
            animate("opacity", from: oldReviewOpacity, to: 0, duration: 0.08, on: clip, name: "reveal")
        }
    }
    func finishContraction() {
        capsule.removeAnimation(forKey: "islandShape"); capsule.removeAnimation(forKey: "islandPosition")
        reviewView?.removeFromSuperview(); reviewView = nil
        reviewClip.isHidden = true; reviewClip.layer?.removeAllAnimations()
        reviewMask.removeAllAnimations()
        expanded = false; contractingFrame = nil; compactCenter = nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.opacity = 1
        CATransaction.commit()
        setAccessibilityElement(true)
        layout()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { capsule.frame.contains(point) ? super.hitTest(point) : nil }
    override func accessibilityPerformPress() -> Bool {
        guard status?.needsDetails == true else { return false }
        details(); return true
    }
}

@MainActor
final class CorrectionStatusPresenter {
    let panel: StatusPanel
    private let pill: StatusPillView
    private var lastAnchor: SelectionAnchor?
    private var lastFrame: NSRect?
    private var lastPillFrame: NSRect?
    // Only geometry survives dismissal, scoped to the source app. No draft is kept.
    private var rememberedPlacement: (pid: pid_t, anchor: SelectionAnchor)?
    private var reviewPreferredHeight: CGFloat = 300
    private(set) var isReviewExpanded = false
    private var contraction: Task<Void, Never>?
    private var dismissal: Task<Void, Never>?
    private var tracking: Task<Void, Never>?
    private var current: CorrectionStatus?
    private var suspended = false
    private let frontmost: () -> pid_t?
    private let ownPID: pid_t
    private let activateReview: () -> Void
    private let activateSource: (pid_t) -> Bool
    private let reviewIsKey: (NSWindow) -> Bool
    private var reviewSourcePID: pid_t?
    private var wantsReviewFocus = false
    private var restoringSource = false
    private var focusAcquisition: Task<Void, Never>?
    private var pendingExpansion: (() -> Void)?
    private var applicationDeactivationObserver: NSObjectProtocol?
    var isReviewWaitingForFocus: Bool { pendingExpansion != nil }
    private var focusSession = UUID()

    init(frontmost: @escaping () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
         activateReview: @escaping () -> Void = { NSApplication.shared.activate() },
         activateSource: @escaping (pid_t) -> Bool = { pid in
             guard let source = NSRunningApplication(processIdentifier: pid), !source.isTerminated else { return false }
             NSApplication.shared.yieldActivation(to: source)
             return source.activate(from: .current, options: [])
         },
         reviewIsKey: @escaping (NSWindow) -> Bool = {
             NSApplication.shared.isActive && NSApplication.shared.keyWindow === $0 && $0.isKeyWindow
         },
         details: @escaping () -> Void) {
        self.frontmost = frontmost; self.ownPID = ownPID
        self.activateReview = activateReview; self.activateSource = activateSource; self.reviewIsKey = reviewIsKey
        pill = StatusPillView(details: details)
        func makePanel() -> StatusPanel {
            let panel = StatusPanel(contentRect: .zero,
                styleMask: [.borderless], backing: .buffered, defer: false)
            panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = false
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
            panel.ignoresMouseEvents = true
            panel.becomesKeyOnlyIfNeeded = false
            return panel
        }
        panel = makePanel()
        panel.contentView = pill
        panel.reviewFocusLost = { [weak self] in self?.reviewLostFocus() }
        applicationDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApplication.shared, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reviewLostFocus() }
        }
    }

    private func reviewLostFocus() {
        guard isReviewExpanded, wantsReviewFocus, pendingExpansion == nil, !restoringSource else { return }
        // A visible review must never promise Return while another window owns it.
        // The correction remains in the coordinator for explicit reopening.
        suspend()
    }

    // AX and AppKit share point units but opposite Y axes, even on Retina displays.
    // Flip around the PRIMARY display, not the display containing the selection.
    static func appKitRect(_ rect: CGRect, primaryTop: CGFloat) -> NSRect {
        NSRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    static func frame(anchor: NSRect?, field: NSRect? = nil,
                      previous: NSRect? = nil, visibleFrame: NSRect, centeredFallback: Bool = false) -> NSRect {
        let size = StatusPillView.canvasSize
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        guard let input = field ?? anchor else {
            if centeredFallback {
                return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height)
            }
            return NSRect(x: bounds.maxX - size.width, y: bounds.minY, width: size.width, height: size.height)
        }
        // Centre on the input, never on the selected words. The clear canvas margin
        // gives the visible capsule a 12-point gap from the field.
        let x = min(max(input.midX - size.width / 2, bounds.minX), bounds.maxX - size.width)
        let above = NSRect(x: x, y: input.maxY + 2, width: size.width, height: size.height)
        let below = NSRect(x: x, y: input.minY - size.height - 2, width: size.width, height: size.height)
        // A high field, such as a browser address bar, should open down into the
        // page rather than squeeze against the toolbar/menu bar. Add hysteresis
        // while tracking so tiny movements cannot make it flip back and forth.
        let wasBelow = previous.map { $0.midY < input.midY } ?? false
        let nearTop = bounds.maxY - input.maxY < (wasBelow ? 110 : 90)
        let candidates = nearTop ? [below, above] : [above, below]
        if let available = candidates.first(where: { bounds.contains($0) }) { return available }
        // Some editors expose the entire viewport as the field. Prefer a screen
        // corner clear of the actual selection when no exterior space exists.
        let corners = [
            NSRect(x: bounds.maxX - size.width, y: bounds.minY, width: size.width, height: size.height),
            NSRect(x: bounds.maxX - size.width, y: bounds.maxY - size.height, width: size.width, height: size.height)
        ]
        return corners.first(where: { corner in anchor.map { !corner.intersects($0) } ?? true }) ?? corners[0]
    }

    static func expandedFrame(pill: NSRect, field: NSRect?, visibleFrame: NSRect, preferredHeight: CGFloat = 300) -> NSRect {
        let bounds = visibleFrame.insetBy(dx: 8, dy: 8)
        let width = min(440, bounds.width)
        let x = min(max(pill.midX - width / 2, bounds.minX), bounds.maxX - width)
        if let field {
            let above = max(0, bounds.maxY - field.maxY - 2)
            let below = max(0, field.minY - bounds.minY - 2)
            var opensBelow = pill.midY < field.midY
            let available = opensBelow ? below : above
            if available < 200 && (opensBelow ? above : below) > available { opensBelow.toggle() }
            let room = opensBelow ? below : above
            if room >= 200 {
                let height = min(preferredHeight, room)
                return NSRect(x: x, y: opensBelow ? field.minY - height - 2 : field.maxY + 2,
                              width: width, height: height)
            }
        }
        let height = min(preferredHeight, bounds.height)
        let y = min(max(pill.minY, bounds.minY), bounds.maxY - height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    private static func distance(_ a: NSRect, _ b: NSRect) -> CGFloat { hypot(a.midX - b.midX, a.midY - b.midY) }

    /// Keep the last selection geometry when an editor collapses it after paste.
    /// A moving field translates the selection along with it.
    static func stabilized(_ next: SelectionAnchor, previous: SelectionAnchor?) -> SelectionAnchor {
        guard next.selection == nil, let previous,
              let oldField = previous.field, let field = next.field else { return next }
        let dx = field.minX - oldField.minX, dy = field.minY - oldField.minY
        var result = next
        result.selection = previous.selection.map { $0.offsetBy(dx: dx, dy: dy).intersection(field) }.flatMap { SelectionAnchor.valid($0) ? $0 : nil }
        return result
    }

    @discardableResult
    private func position(_ anchor: SelectionAnchor?, centeredFallback: Bool = false) -> Bool {
        let anchor = anchor.map { Self.stabilized($0, previous: lastAnchor) }
        let screens = NSScreen.screens
        guard let primary = screens.first else { return false }
        let raw = anchor?.selection ?? anchor?.field
        let rect = raw.flatMap { SelectionAnchor.valid($0) ? Self.appKitRect($0, primaryTop: primary.frame.maxY) : nil }
        let screen: NSScreen
        if let rect {
            guard let match = screens.max(by: { Self.area($0.visibleFrame.intersection(rect)) < Self.area($1.visibleFrame.intersection(rect)) }),
                  Self.area(match.visibleFrame.intersection(rect)) > 0 else { return false }
            screen = match
        } else { screen = NSScreen.main ?? primary }
        let visible = rect.map { $0.intersection(screen.visibleFrame) }
        func converted(_ raw: CGRect?) -> NSRect? {
            raw.flatMap { SelectionAnchor.valid($0) ? Self.appKitRect($0, primaryTop: primary.frame.maxY).intersection(screen.visibleFrame) : nil }
                .flatMap { SelectionAnchor.valid($0) ? $0 : nil }
        }
        let field = converted(anchor?.field)
        let compact = Self.frame(anchor: visible, field: field, previous: lastPillFrame, visibleFrame: screen.visibleFrame, centeredFallback: centeredFallback)
        lastPillFrame = compact
        let frame = isReviewExpanded ? Self.expandedFrame(pill: compact, field: field, visibleFrame: screen.visibleFrame, preferredHeight: reviewPreferredHeight) : compact
        let scale = screen.backingScaleFactor
        let aligned = NSRect(x: (frame.minX * scale).rounded() / scale, y: (frame.minY * scale).rounded() / scale,
                             width: frame.width, height: frame.height)
        lastAnchor = anchor
        if let lastFrame, Self.distance(lastFrame, aligned) < 0.75 { return true }
        let animate = !isReviewExpanded && panel.isVisible && lastFrame.map { Self.distance($0, aligned) < 100 } == true && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10; context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(aligned, display: true)
            }
        } else { panel.setFrame(aligned, display: true) }
        lastFrame = aligned
        return true
    }

    private static func area(_ rect: NSRect) -> CGFloat { rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height }

    func show(_ status: CorrectionStatus, anchor: SelectionAnchor? = nil, sourcePID: pid_t? = nil,
              follow: (@Sendable () async -> SelectionAnchor?)? = nil,
              isCurrent: (@MainActor () async -> Bool)? = nil) {
        guard !suspended else { return }
        guard sourcePID == nil || frontmost() == sourcePID else { suspend(); return }
        if isReviewExpanded {
            contractReview(to: status, sourcePID: sourcePID, follow: follow, isCurrent: isCurrent)
            return
        }
        if contraction != nil { current = status; pill.update(status, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion); return }
        guard current != status else { return }
        dismissal?.cancel(); tracking?.cancel(); current = status
        pill.update(status, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        panel.ignoresMouseEvents = !status.needsDetails
        let remembered = status == .noText && rememberedPlacement?.pid == sourcePID ? rememberedPlacement?.anchor : nil
        guard position(lastAnchor ?? anchor ?? remembered, centeredFallback: status == .noText) else { suspend(); return }
        rememberPlacement(sourcePID: sourcePID)
        panel.orderFrontRegardless(); pill.setVisible(true)
        if status == .noText { pill.shake() }
        startTracking(status: status, sourcePID: sourcePID, follow: follow, isCurrent: isCurrent)
        guard !status.busy else { return }
        dismissal = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(status.needsDetails && status != .noText ? 8 : 1.8))
                guard let self else { return }
                pill.setVisible(false)
                try await Task.sleep(for: .milliseconds(250))
                hide()
            } catch { }
        }
    }

    private func rememberPlacement(sourcePID: pid_t?) {
        guard let sourcePID, let lastAnchor, lastAnchor.field != nil || lastAnchor.selection != nil else { return }
        rememberedPlacement = (sourcePID, lastAnchor)
    }

    func showReview(coordinator: ProofreadingCoordinator, anchor: SelectionAnchor? = nil,
                    sourcePID: pid_t? = nil, follow: (@Sendable () async -> SelectionAnchor?)? = nil,
                    isCurrent: (@MainActor () async -> Bool)? = nil,
                    focus: Bool = true, apply: @escaping () -> Void, collapse: @escaping () -> Void) {
        guard !suspended else { return }
        guard acceptsForeground(sourcePID: sourcePID) else { suspend(); return }
        let status = coordinator.correctionStatus ?? .review
        if isReviewExpanded {
            current = status; pill.update(status, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            if wantsReviewFocus && !restoringSource &&
                (!panel.allowsReviewFocus || (pendingExpansion != nil && focusAcquisition == nil)) { acquireReviewFocus() }
            return // The observable review updates in place, preserving scroll/selection.
        }
        let interruptedBounds = contraction == nil ? nil : pill.capsule.presentation()?.bounds ?? pill.capsule.bounds
        let interruptedPosition = contraction == nil ? nil : pill.capsule.presentation()?.position ?? pill.capsule.position
        let interruptedCorner = contraction == nil ? nil : pill.capsule.presentation()?.cornerRadius ?? pill.capsule.cornerRadius
        let interruptedCenter = interruptedPosition.map { CGPoint(x: panel.frame.minX + $0.x, y: panel.frame.minY + $0.y) }
        contraction?.cancel(); contraction = nil
        pill.finishContraction()
        if !panel.isVisible { show(status, anchor: anchor, sourcePID: sourcePID, follow: follow, isCurrent: isCurrent) }
        guard panel.isVisible else { return }
        dismissal?.cancel(); dismissal = nil; tracking?.cancel()
        pill.update(status, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let oldBounds = interruptedBounds ?? pill.capsule.presentation()?.bounds ?? pill.capsule.bounds
        let oldCorner = interruptedCorner ?? pill.capsule.presentation()?.cornerRadius ?? pill.capsule.cornerRadius
        let center = pill.capsule.presentation()?.position ?? pill.capsule.position
        let globalCenter = interruptedCenter ?? CGPoint(x: panel.frame.minX + center.x, y: panel.frame.minY + center.y)
        reviewPreferredHeight = IslandReviewView.preferredHeight(for: coordinator, width: 440)
        isReviewExpanded = true; current = status
        reviewSourcePID = sourcePID ?? frontmost().flatMap { $0 == ownPID ? nil : $0 }
        wantsReviewFocus = focus
        panel.ignoresMouseEvents = false; panel.allowsReviewFocus = true
        panel.reviewKeyAction = nil
        pendingExpansion = { [weak self] in
            guard let self else { return }
            guard self.position(self.lastAnchor ?? anchor) else { self.suspend(); return }
            let host = NSHostingView(rootView: IslandReviewView(coordinator: coordinator, apply: {
                guard coordinator.canApply else { return }; apply()
            }, collapse: collapse))
            host.sizingOptions = []
            self.pill.expand(with: host, from: oldBounds,
                position: CGPoint(x: globalCenter.x - self.panel.frame.minX, y: globalCenter.y - self.panel.frame.minY), cornerRadius: oldCorner)
            self.panel.reviewKeyAction = { action in
                switch action {
                case .apply: if coordinator.canApply { apply() }
                case .collapse: if !coordinator.applying { collapse() }
                }
            }
        }
        panel.orderFrontRegardless()
        if focus { acquireReviewFocus() } else { finishFocusAcquisition() }
        startTracking(status: status, sourcePID: sourcePID, follow: follow, isCurrent: isCurrent)
    }

    private func finishFocusAcquisition() {
        let expand = pendingExpansion; pendingExpansion = nil
        expand?()
    }

    private func acceptsForeground(sourcePID: pid_t?) -> Bool {
        if isReviewExpanded && wantsReviewFocus {
            // Activation can take multiple run-loop turns. While acquiring it, keep
            // the compact indicator, but abandon review if the user switches elsewhere.
            guard let active = frontmost() else { return true }
            return active == ownPID || active == reviewSourcePID
        }
        return sourcePID == nil || frontmost() == sourcePID
    }

    private func acquireReviewFocus() {
        focusAcquisition?.cancel(); focusSession = UUID()
        let session = focusSession
        panel.allowsReviewFocus = true
        activateReview()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(pill)
        focusAcquisition = Task { [weak self] in
            guard let self else { return }
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .milliseconds(750))
            var focusedSince: ContinuousClock.Instant?
            while !Task.isCancelled && focusSession == session && isReviewExpanded {
                let active = frontmost()
                if let active, active != ownPID && active != reviewSourcePID { suspend(); return }
                if active == ownPID && reviewIsKey(panel) {
                    if focusedSince == nil { focusedSince = clock.now }
                    if let focusedSince, clock.now - focusedSince >= .milliseconds(50) {
                        focusAcquisition = nil; finishFocusAcquisition(); return
                    }
                } else {
                    focusedSince = nil
                    if active == ownPID || active == reviewSourcePID {
                        panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(pill)
                    }
                }
                // Failed activation leaves a clickable compact indicator, never an
                // expanded panel whose Return key still belongs to the message field.
                guard clock.now < deadline else { focusAcquisition = nil; return }
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    /// Activation requests are asynchronous. No replacement may start until the
    /// original source actually becomes active, and a third app is never overridden.
    func restoreSourceFocus() async throws {
        let active = frontmost()
        guard isReviewExpanded, pendingExpansion == nil, wantsReviewFocus, active == ownPID,
              reviewIsKey(panel), panel.allowsReviewFocus else { throw AppFailure.focusChanged }
        let session = focusSession
        focusAcquisition?.cancel(); focusAcquisition = nil
        tracking?.cancel(); tracking = nil
        restoringSource = true
        defer { restoringSource = false }
        panel.allowsReviewFocus = false
        panel.orderOut(nil); panel.orderFrontRegardless()
        guard let source = reviewSourcePID else { wantsReviewFocus = false; return }
        // Closing a key panel may already have restored the original application.
        if frontmost() == source { wantsReviewFocus = false; return }
        do {
            guard frontmost() == ownPID, activateSource(source) else { throw AppFailure.focusChanged }
            let clock = ContinuousClock(), deadline = clock.now.advanced(by: .milliseconds(750))
            while true {
                try Task.checkCancellation()
                guard focusSession == session, isReviewExpanded else { throw AppFailure.focusChanged }
                let active = frontmost()
                if active == source { wantsReviewFocus = false; return }
                guard active == nil || active == ownPID, clock.now < deadline else { throw AppFailure.focusChanged }
                try await Task.sleep(for: .milliseconds(16))
            }
        } catch {
            // Keep the failure readable if we're still active. Never reclaim focus
            // from another app the user selected during the handoff.
            if focusSession == session, isReviewExpanded, frontmost() == ownPID {
                acquireReviewFocus()
            }
            throw error
        }
    }

    private func contractReview(to status: CorrectionStatus, sourcePID: pid_t?,
                                follow: (@Sendable () async -> SelectionAnchor?)?,
                                isCurrent: (@MainActor () async -> Bool)?) {
        dismissal?.cancel(); dismissal = nil; tracking?.cancel(); tracking = nil
        isReviewExpanded = false; current = status
        pendingExpansion = nil
        focusAcquisition?.cancel(); focusAcquisition = nil; wantsReviewFocus = false
        panel.reviewKeyAction = nil; panel.allowsReviewFocus = false
        panel.ignoresMouseEvents = true
        // A successful source handoff has already released keyboard focus. Also
        // release any remaining key panel when contracting without replacement.
        if panel.isKeyWindow { panel.orderOut(nil); panel.orderFrontRegardless() }
        let compact = lastPillFrame ?? panel.frame
        pill.update(status, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        pill.contract(to: compact.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY))
        let delay: Duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .zero : .milliseconds(Int(StatusPillView.collapseDuration * 1_000) + 20)
        contraction = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            contraction = nil
            panel.setFrame(compact, display: true); lastFrame = compact
            pill.finishContraction()
            let next = current ?? status; current = nil
            show(next, sourcePID: sourcePID, follow: follow, isCurrent: isCurrent)
        }
    }

    private func startTracking(status: CorrectionStatus, sourcePID: pid_t?,
                               follow: (@Sendable () async -> SelectionAnchor?)?,
                               isCurrent: (@MainActor () async -> Bool)?) {
        tracking?.cancel()
        guard sourcePID != nil || follow != nil || isCurrent != nil || (isReviewExpanded && wantsReviewFocus) else { return }
        tracking = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self else { return }
                guard acceptsForeground(sourcePID: sourcePID) else { suspend(); return }
                if let isCurrent {
                    let valid = await isCurrent()
                    guard !Task.isCancelled else { return }
                    guard valid else { suspend(); return }
                    guard acceptsForeground(sourcePID: sourcePID) else { suspend(); return }
                }
                pill.update(current ?? status, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                if isReviewExpanded && wantsReviewFocus {
                    if pendingExpansion != nil {
                        // A click can complete activation after the initial timeout.
                        if focusAcquisition == nil && frontmost() == ownPID && reviewIsKey(panel) { acquireReviewFocus() }
                    } else if !restoringSource && (!reviewIsKey(panel) || frontmost() == reviewSourcePID) {
                        suspend(); return
                    }
                    continue
                }
                if let follow {
                    let next = await follow()
                    guard !Task.isCancelled else { return }
                    guard let next, position(next) else { suspend(); return }
                    rememberPlacement(sourcePID: sourcePID)
                }
            }
        }
    }

    func resumeReview() { suspended = false }

    private func suspend() { hide(); suspended = true }

    func hide() {
        suspended = false
        dismissal?.cancel(); dismissal = nil; tracking?.cancel(); tracking = nil; current = nil
        contraction?.cancel(); contraction = nil; isReviewExpanded = false
        focusAcquisition?.cancel(); focusAcquisition = nil; focusSession = UUID()
        pendingExpansion = nil
        reviewSourcePID = nil; wantsReviewFocus = false; restoringSource = false
        panel.reviewKeyAction = nil; panel.allowsReviewFocus = false
        pill.reset(); panel.orderOut(nil)
        lastAnchor = nil; lastFrame = nil; lastPillFrame = nil
    }

    isolated deinit {
        dismissal?.cancel(); tracking?.cancel(); contraction?.cancel(); focusAcquisition?.cancel()
        if let applicationDeactivationObserver { NotificationCenter.default.removeObserver(applicationDeactivationObserver) }
    }
}
