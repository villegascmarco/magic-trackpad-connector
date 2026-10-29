import AppKit
import SwiftUI

/// SF Symbols and Control Center–style round badges for devices and Macs, so
/// the menu and Settings show the same glyphs the system Bluetooth menu does.
enum DeviceIcon {
    static func symbol(forDevice name: String) -> String {
        let name = name.lowercased()
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if name.contains("keyboard") { return "keyboard.fill" }
        if name.contains("mouse") { return "magicmouse.fill" }
        if name.contains("airpods") { return "airpods.pro" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("ipad") { return "ipad" }
        if name.contains("watch") { return "applewatch" }
        if name.contains("pencil") || name.contains("intuos") || name.contains("wacom") { return "pencil.tip" }
        return "dot.radiowaves.left.and.right"
    }

    static func symbol(forMac name: String) -> String {
        let name = name.lowercased()
        if name.contains("book") { return "laptopcomputer" }
        if name.contains("mini") || name.contains("studio") { return "macmini.fill" }
        return "desktopcomputer"
    }

    /// A 26 pt circle: accent-filled when active, gray otherwise. Drawn lazily,
    /// so it follows light/dark mode and the accent color.
    static func badge(_ symbol: String, active: Bool) -> NSImage {
        let size = NSSize(width: 26, height: 26)
        let image = NSImage(size: size, flipped: false) { rect in
            let fill: NSColor = active ? .controlAccentColor : .quaternaryLabelColor
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let tint: NSColor = active ? .white : .labelColor
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(.init(paletteColors: [tint]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let g = glyph.size
                glyph.draw(in: NSRect(x: rect.midX - g.width / 2, y: rect.midY - g.height / 2,
                                      width: g.width, height: g.height))
            }
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// SwiftUI counterpart of `DeviceIcon.badge` for Settings rows.
struct DeviceBadge: View {
    let symbol: String
    var active = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: 28, height: 28)
            .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: .circle)
    }
}
