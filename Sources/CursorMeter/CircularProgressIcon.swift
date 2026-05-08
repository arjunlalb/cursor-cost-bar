import AppKit

// MARK: - Progress Level

enum ProgressLevel: Sendable, Equatable {
    case normal
    case warning
    case critical

    var color: NSColor {
        switch self {
        case .normal: .systemGreen
        case .warning: .systemYellow
        case .critical: .systemRed
        }
    }
}

// MARK: - Circular Progress Icon

enum CircularProgressIcon {
    static func level(for percent: Double) -> ProgressLevel {
        if percent >= 90 { return .critical }
        if percent >= 70 { return .warning }
        return .normal
    }

    /// Pie chart icon only
    static func menuBarImage(percent: Double, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawPie(in: ctx, rect: rect, percent: percent)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Pie chart + fraction text (used / limit) as a single NSImage
    static func menuBarImageWithText(percent: Double, usedText: String, limitText: String) -> NSImage {
        let pieSize: CGFloat = 20
        let font = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
        let textColor = NSColor.labelColor

        let usedStr = NSAttributedString(string: usedText, attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let limitStr = NSAttributedString(string: limitText, attributes: [
            .font: font, .foregroundColor: textColor,
        ])

        let usedSize = usedStr.size()
        let limitSize = limitStr.size()
        let textWidth = max(usedSize.width, limitSize.width)
        let lineHeight: CGFloat = 1
        let textBlockHeight = usedSize.height + lineHeight + limitSize.height
        let gap: CGFloat = 3

        let totalWidth = pieSize + gap + textWidth + 1
        let totalHeight: CGFloat = 22

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw pie (vertically centered)
            let pieY = (totalHeight - pieSize) / 2
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pieY)
            let pieRect = CGRect(x: 0, y: 0, width: pieSize, height: pieSize)
            drawPie(in: ctx, rect: pieRect, percent: percent)
            ctx.restoreGState()

            // Draw fraction text (vertically centered)
            let textX = pieSize + gap
            let textY = (totalHeight - textBlockHeight) / 2

            // Limit (bottom)
            limitStr.draw(at: NSPoint(
                x: textX + (textWidth - limitSize.width) / 2,
                y: textY
            ))

            // Divider line
            let lineY = textY + limitSize.height + lineHeight / 2
            ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.6).cgColor)
            ctx.setLineWidth(1.0)
            ctx.move(to: CGPoint(x: textX, y: lineY))
            ctx.addLine(to: CGPoint(x: textX + textWidth, y: lineY))
            ctx.strokePath()

            // Used (top)
            usedStr.draw(at: NSPoint(
                x: textX + (textWidth - usedSize.width) / 2,
                y: textY + limitSize.height + lineHeight
            ))

            return true
        }
        image.isTemplate = false
        return image
    }

    /// Pie chart + percent text as a single NSImage
    static func menuBarImageWithPercent(percent: Double) -> NSImage {
        let pieSize: CGFloat = 20
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let textColor = NSColor.labelColor

        let percentStr = NSAttributedString(string: "\(Int(percent))%", attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let textSize = percentStr.size()
        let gap: CGFloat = 3

        let totalWidth = pieSize + gap + textSize.width + 1
        let totalHeight: CGFloat = 22

        let image = NSImage(size: NSSize(width: totalWidth, height: totalHeight), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }

            // Draw pie (vertically centered)
            let pieY = (totalHeight - pieSize) / 2
            ctx.saveGState()
            ctx.translateBy(x: 0, y: pieY)
            let pieRect = CGRect(x: 0, y: 0, width: pieSize, height: pieSize)
            drawPie(in: ctx, rect: pieRect, percent: percent)
            ctx.restoreGState()

            // Draw percent text (vertically centered)
            let textX = pieSize + gap
            let textY = (totalHeight - textSize.height) / 2
            percentStr.draw(at: NSPoint(x: textX, y: textY))

            return true
        }
        image.isTemplate = false
        return image
    }

    /// "Cursor Meter" text icon for idle/not-logged-in state
    static func idleImage() -> NSImage {
        let topFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let bottomFont = NSFont.systemFont(ofSize: 6, weight: .regular)
        let color = NSColor.labelColor

        let topStr = NSAttributedString(string: "Cursor", attributes: [
            .font: topFont, .foregroundColor: color,
        ])
        let bottomStr = NSAttributedString(string: "Meter", attributes: [
            .font: bottomFont, .foregroundColor: color,
        ])

        let topSize = topStr.size()
        let bottomSize = bottomStr.size()
        let width = max(topSize.width, bottomSize.width) + 2
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            let totalText = topSize.height + bottomSize.height
            let startY = (height - totalText) / 2

            bottomStr.draw(at: NSPoint(
                x: (width - bottomSize.width) / 2,
                y: startY
            ))
            topStr.draw(at: NSPoint(
                x: (width - topSize.width) / 2,
                y: startY + bottomSize.height
            ))
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Renders an emoji glyph centered in a fixed-size NSImage suitable for
    /// `NSStatusItem.button.image` swap. Used for the usage-jump effect.
    ///
    /// The returned image's `size` matches the requested `size` exactly so that
    /// swapping it onto a pinned-length status item never shifts the slot.
    ///
    /// - Parameters:
    ///   - emoji: single Unicode scalar / sequence (e.g. `"⚡"`, `"🚀"`).
    ///   - size: target image size; should match the ring image size.
    ///   - glow: when `true`, attaches a red drop-shadow halo behind the glyph.
    static func makeEmojiImage(emoji: String, size: NSSize, glow: Bool = false) -> NSImage {
        // Font sized so a typical emoji glyph fills ~78% of the image height.
        let fontSize = size.height * 0.78
        let font = NSFont.systemFont(ofSize: fontSize)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]

        if glow {
            let shadow = NSShadow()
            shadow.shadowBlurRadius = max(2, size.height * 0.18)
            shadow.shadowColor = NSColor.systemRed.withAlphaComponent(0.6)
            shadow.shadowOffset = .zero
            attrs[.shadow] = shadow
        }

        let attributed = NSAttributedString(string: emoji, attributes: attrs)
        let textSize = attributed.size()

        let image = NSImage(size: size, flipped: false) { rect in
            // Slight inset keeps any drop-shadow halo within image bounds.
            let inset: CGFloat = glow ? max(1, rect.height * 0.08) : 0
            let drawRect = rect.insetBy(dx: inset, dy: inset)

            // Center the glyph: NSAttributedString.draw uses the typographic
            // bounding box, so subtract the measured size from the available
            // box to obtain origin for visual centering.
            let originX = drawRect.minX + (drawRect.width - textSize.width) / 2
            let originY = drawRect.minY + (drawRect.height - textSize.height) / 2
            attributed.draw(at: NSPoint(x: originX, y: originY))
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: - Private

    private static func pieColor(for percent: Double) -> NSColor {
        if percent >= 90 { return NSColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1) }
        if percent >= 70 { return NSColor(red: 0.95, green: 0.65, blue: 0.0, alpha: 1) }
        return NSColor(red: 0.20, green: 0.70, blue: 0.25, alpha: 1)
    }

    private static func drawPie(in ctx: CGContext, rect: CGRect, percent: Double) {
        let inset: CGFloat = 1
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = (min(rect.width, rect.height) - inset * 2) / 2

        // Track (adapts to system appearance)
        ctx.setFillColor(NSColor.labelColor.withAlphaComponent(0.2).cgColor)
        let circleRect = CGRect(x: center.x - radius, y: center.y - radius,
                                width: radius * 2, height: radius * 2)
        ctx.addEllipse(in: circleRect)
        ctx.fillPath()

        // Border
        ctx.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(0.75)
        ctx.addEllipse(in: circleRect)
        ctx.strokePath()

        // Pie wedge
        let progress = min(max(percent / 100.0, 0), 1.0)
        if progress > 0 {
            let nsColor = pieColor(for: percent)
            ctx.setFillColor(nsColor.cgColor)

            let startAngle = CGFloat.pi / 2
            let endAngle = startAngle - (2 * .pi * progress)

            ctx.move(to: center)
            ctx.addArc(center: center, radius: radius,
                       startAngle: startAngle, endAngle: endAngle, clockwise: true)
            ctx.closePath()
            ctx.fillPath()
        }
    }
}
