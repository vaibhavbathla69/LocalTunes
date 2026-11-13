import Foundation
import CoreGraphics
import ImageIO

struct ArtworkColors: Equatable, Sendable {
    struct RGB: Equatable, Sendable {
        var red: Double
        var green: Double
        var blue: Double
        var brightness: Double { max(red, max(green, blue)) }
    }
    var primary: RGB
    var secondary: RGB
    var accent: RGB

    static let `default` = fallback(seed: "LocalTunes")

    static func fallback(seed: String) -> Self {
        // Stable across launches, unlike Swift's randomized hashValue.
        let hash = seed.utf8.reduce(UInt64(2166136261)) { ($0 ^ UInt64($1)) &* 16777619 }
        let hue = Double(hash % 360) / 360
        return Self(primary: hsv(hue, 0.65, 0.7), secondary: hsv(hue + 0.15, 0.7, 0.48), accent: hsv(hue, 0.48, 1))
    }

    static func extract(from image: CGImage) -> Self? {
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        struct Bucket {
            var weight = 0.0, red = 0.0, green = 0.0, blue = 0.0
            var color: RGB { RGB(red: red / weight, green: green / weight, blue: blue / weight) }
        }
        var buckets: [Int: Bucket] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[index + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = min(1, Double(pixels[index]) / 255 / alpha)
            let g = min(1, Double(pixels[index + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[index + 2]) / 255 / alpha)
            let high = max(r, max(g, b)), low = min(r, min(g, b))
            let saturation = high > 0 ? (high - low) / high : 0
            guard high > 0.09, !(high > 0.94 && saturation < 0.12) else { continue }
            let weight = 0.15 + saturation * saturation * 2
            let key = (Int(r * 7) << 6) | (Int(g * 7) << 3) | Int(b * 7)
            var bucket = buckets[key, default: Bucket()]
            bucket.weight += weight; bucket.red += r * weight; bucket.green += g * weight; bucket.blue += b * weight
            buckets[key] = bucket
        }
        let ranked = buckets.values.sorted { $0.weight > $1.weight }
        guard let dominant = ranked.first?.color else { return nil }
        let alternate = ranked.dropFirst().first { bucket in
            let c = bucket.color
            return abs(c.red - dominant.red) + abs(c.green - dominant.green) + abs(c.blue - dominant.blue) > 0.65
        }?.color ?? RGB(red: dominant.red * 0.6, green: dominant.green * 0.6, blue: dominant.blue * 0.6)
        func lift(_ color: RGB, brightness: Double) -> RGB {
            let scale = brightness / max(0.12, color.brightness)
            return RGB(red: min(1, color.red * scale), green: min(1, color.green * scale), blue: min(1, color.blue * scale))
        }
        return Self(primary: lift(dominant, brightness: 0.75), secondary: lift(alternate, brightness: 0.6), accent: lift(dominant, brightness: 1))
    }

    private static func hsv(_ hue: Double, _ saturation: Double, _ value: Double) -> RGB {
        let h = (hue - floor(hue)) * 6
        let sector = Int(h), f = h - Double(sector)
        let p = value * (1 - saturation), q = value * (1 - f * saturation), t = value * (1 - (1 - f) * saturation)
        switch sector {
        case 0: return RGB(red: value, green: t, blue: p)
        case 1: return RGB(red: q, green: value, blue: p)
        case 2: return RGB(red: p, green: value, blue: t)
        case 3: return RGB(red: p, green: q, blue: value)
        case 4: return RGB(red: t, green: p, blue: value)
        default: return RGB(red: value, green: p, blue: q)
        }
    }
}

actor ArtworkColorLoader {
    static let shared = ArtworkColorLoader()
    private var cache: [String: ArtworkColors] = [:]
    private var order: [String] = []

    func colors(artwork: URL?, seed: String) -> ArtworkColors {
        guard let artwork else { return .fallback(seed: seed) }
        let key = artwork.path
        if let cached = cache[key] { return cached }
        var result = ArtworkColors.fallback(seed: seed)
        if let source = CGImageSourceCreateWithURL(artwork as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64
           ] as CFDictionary), let colors = ArtworkColors.extract(from: image) { result = colors }
        if order.count >= 256 { cache.removeValue(forKey: order.removeFirst()) }
        order.append(key); cache[key] = result
        return result
    }
}
