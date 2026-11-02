import AppKit

/// The menu bar glyph. It stays a template image so that the system tints it for
/// whatever is behind the menu bar, and the badge sits on top as a separate colored
/// view, because a template image can't carry color of its own.
@MainActor
final class StatusIcon {
    enum Badge {
        case none, starting, failed
    }

    private let button: NSStatusBarButton
    private let dot = BadgeDot()
    private var badge = Badge.none

    private static let size = NSSize(width: 20, height: 18)
    private static let dotDiameter: CGFloat = 7
    /// From the center of the icon to the center of the badge. Down and to the right.
    private static let dotOffset = NSPoint(x: 6, y: 5)

    init(button: NSStatusBarButton) {
        self.button = button
        button.image = Self.glyph(cutOut: false)
        button.imagePosition = .imageOnly

        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.heightAnchor.constraint(equalToConstant: Self.dotDiameter),
            dot.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: Self.dotOffset.x),
            dot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: Self.dotOffset.y),
        ])
    }

    func update(badge: Badge, idle: Bool, description: String) {
        button.appearsDisabled = idle
        button.toolTip = description
        button.setAccessibilityLabel(description)

        guard badge != self.badge else { return }
        self.badge = badge
        button.image = Self.glyph(cutOut: badge != .none)
        dot.color = badge == .failed ? .systemRed : .systemOrange
        dot.isHidden = badge == .none
        dot.pulsing = badge == .starting
    }

    /// Three rack units, drawn on whole points because SF Symbols' `server.rack` turns
    /// to mush on 1x displays. The badge gets a gap around it, punched out of the
    /// glyph, so it stays readable in both light and dark menu bars.
    private static func glyph(cutOut: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            for row in 0..<3 {
                let y = 2 + CGFloat(row) * 5
                NSBezierPath(
                    roundedRect: NSRect(x: 3, y: y, width: 14, height: 3),
                    xRadius: 1,
                    yRadius: 1
                ).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSRect(x: 5, y: y + 1, width: 3, height: 1).fill(using: .destinationOut)
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            if cutOut {
                let radius = dotDiameter / 2 + 1.5
                let center = NSPoint(x: rect.midX + dotOffset.x, y: rect.midY - dotOffset.y)
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                NSColor.black.setFill()
                NSBezierPath(
                    ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                ).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

private final class BadgeDot: NSView {
    var color = NSColor.systemRed {
        didSet { needsDisplay = true }
    }

    var pulsing = false {
        didSet {
            layer?.removeAnimation(forKey: "pulse")
            guard pulsing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.25
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(pulse, forKey: "pulse")
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    /// Clicks go through to the status button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
