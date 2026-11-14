import Foundation

enum ThemeContrast {
    static func components(_ hex: String, dark: Bool, adjust: Bool = true) -> (Double, Double, Double) {
        let value = UInt32(hex, radix: 16) ?? 0xFA243C
        var rgb = (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
        guard adjust else { return rgb }
        for _ in 0..<40 {
            let light = luminance(rgb)
            let contrast = dark ? (light + 0.05) / 0.05 : 1.05 / (light + 0.05)
            if contrast >= 4.5 { break }
            if dark { rgb = (rgb.0 + (1 - rgb.0) * 0.1, rgb.1 + (1 - rgb.1) * 0.1, rgb.2 + (1 - rgb.2) * 0.1) }
            else { rgb = (rgb.0 * 0.9, rgb.1 * 0.9, rgb.2 * 0.9) }
        }
        return rgb
    }
    static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }
}
