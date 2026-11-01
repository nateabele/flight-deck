import SwiftUI
import UIKit

/// The planning instruments' colours on the phone — the same light/dark pairs, under the same
/// names, as the Mac's `InstrumentPalette.swift`, so the board strip, transport keys and the
/// round screens follow the system appearance exactly as the desktop's instruments do.
///
/// The dark halves are the instruments' original fixed colours. The light halves keep the same
/// roles: the glass becomes a pale panel, phosphor a slate ink, and the signal colours (blue,
/// amber, red) darken enough to read on it. Keep the values in step with the Mac's file.
///
/// `lift` is the one colour that inverts rather than adapts: white on the dark glass, black on
/// the light one. It is the hairlines, sheens and hover fills, always used at a low opacity.
enum Instrument {
    // MARK: Ink

    static let phosphor = pair(light: rgb(0x26303F), dark: rgb(0xDBE6F7))
    /// The brightest text: the live round, NOW, the clocks.
    static let ink = pair(light: rgb(0x0D1117), dark: .white)
    /// Text on a fill of `phosphor` or `ink` (a held chip, a hot heatmap cell).
    static let inkInverse = pair(light: .white, dark: UIColor(white: 0.07, alpha: 1))
    static let blue = pair(light: rgb(0x0A5FC8), dark: rgb(0x7CBCFF))
    static let red = pair(light: rgb(0xCF3226), dark: rgb(0xFF6B61))
    /// The LCD's red, a shade warmer than the board's in dark.
    static let lcdRed = pair(light: rgb(0xCF3226), dark: rgb(0xFF7B72))
    /// Amber as text or a glyph.
    static let amber = pair(light: rgb(0xB06400), dark: rgb(0xFFB340))
    /// Amber as a fill (the review bar, NEEDS YOU), under `onAmber` text in either appearance.
    static let amberFill = Color(rgb(0xFFB340))
    static let onAmber = Color(red: 0.106, green: 0.071, blue: 0.016)
    static let lift = pair(light: .black, dark: .white)

    // MARK: Glass

    /// The departures board.
    static let glassTop = pair(light: rgb(0xFBFCFE), dark: rgb(0x13161B))
    static let glassBottom = pair(light: rgb(0xEFF2F6), dark: rgb(0x0C0E11))
    static let glassShadow = pair(light: UIColor(white: 0, alpha: 0.1), dark: UIColor(white: 0, alpha: 0.35))
    /// The split-flap card and the convergence version card, and the nub that joins a card to
    /// its label.
    static let cardTop = pair(light: .white, dark: UIColor(red: 0.102, green: 0.118, blue: 0.145, alpha: 1))
    static let cardBottom = pair(light: rgb(0xF2F5F9), dark: UIColor(red: 0.059, green: 0.071, blue: 0.086, alpha: 1))
    static let cardShadow = pair(light: UIColor(white: 0, alpha: 0.22), dark: UIColor(white: 0, alpha: 0.6))
    /// The card's flap tiles.
    static let tileText = pair(light: rgb(0x161B22), dark: UIColor(red: 0.949, green: 0.965, blue: 0.988, alpha: 1))
    static let tileTop = pair(light: rgb(0xE8ECF2), dark: UIColor(red: 0.165, green: 0.188, blue: 0.227, alpha: 1))
    static let tileBottom = pair(light: rgb(0xDCE2EA), dark: UIColor(red: 0.137, green: 0.157, blue: 0.192, alpha: 1))
    static let tileHinge = pair(light: UIColor(white: 0, alpha: 0.16), dark: UIColor(white: 0, alpha: 0.65))
    /// The control bar's LCD.
    static let lcdTop = pair(light: rgb(0xF4F7FA), dark: UIColor(red: 0.071, green: 0.078, blue: 0.094, alpha: 1))
    static let lcdBottom = pair(light: rgb(0xE8EDF2), dark: UIColor(red: 0.051, green: 0.059, blue: 0.071, alpha: 1))
    static let lcdShadow = pair(light: UIColor(white: 0, alpha: 0.12), dark: UIColor(white: 0, alpha: 0.6))
    /// The control bar around the LCD.
    static let barTop = pair(light: UIColor(white: 0.93, alpha: 1), dark: UIColor(white: 0.184, alpha: 1))
    static let barBottom = pair(light: UIColor(white: 0.9, alpha: 1), dark: UIColor(white: 0.165, alpha: 1))
    static let barHighlight = pair(light: UIColor(white: 1, alpha: 0.7), dark: UIColor(white: 1, alpha: 0.05))
    static let barEdge = pair(light: UIColor(white: 0, alpha: 0.12), dark: UIColor(white: 0, alpha: 0.5))
    /// The recessed well under the transport keys.
    static let well = pair(light: UIColor(white: 0, alpha: 0.05), dark: UIColor(white: 0, alpha: 0.24))
    /// The selection toolbar's chrome.
    static let toolbar = pair(light: UIColor(white: 0.98, alpha: 0.97), dark: UIColor(white: 0.17, alpha: 0.97))
    static let toolbarShadow = pair(light: UIColor(white: 0, alpha: 0.2), dark: UIColor(white: 0, alpha: 0.4))

    private static func pair(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The departures board's roles, as the Mac's `DeparturesBoard.swift` names them: phosphor and
/// its two dimmer steps, the board's signal colours and its glass.
enum Palette {
    static let ph = Instrument.phosphor
    static let ph2 = ph.opacity(0.66)
    static let ph3 = ph.opacity(0.4)
    static let blue2 = Instrument.blue
    static let red = Instrument.red
    static let amber = Instrument.amber
    static let glass0 = Instrument.glassTop
    static let glass1 = Instrument.glassBottom
}
