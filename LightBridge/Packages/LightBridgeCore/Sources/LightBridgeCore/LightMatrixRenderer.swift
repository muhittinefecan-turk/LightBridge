import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

/// Fütüristik noktalı ışık matrisi (Dot-Matrix Optical Light Beacon) üreticisi.
/// Standart kare pikseller yerine; parıldayan dairesel ışık noktaları (dot-matrix)
/// ve donanımsal QR okuyucuların milisaniyeler içinde yakalayabileceği standart optik köşe bulucular üretir.
public final class LightMatrixRenderer {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Verilen metinden noktalı ışık matrisi CGImage üretir.
    public static func render(string: String, targetSize: CGFloat = 800) -> CGImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M" // 15% hata toleransı (daha büyük ve okunması kolay ışık noktaları)
        guard let outputCI = filter.outputImage else { return nil }

        let extent = outputCI.extent
        let modulesWide = Int(extent.width)
        let modulesHigh = Int(extent.height)
        guard modulesWide > 0, modulesHigh > 0 else { return nil }

        var bitmap = [UInt8](repeating: 0, count: modulesWide * modulesHigh)
        ciContext.render(outputCI, toBitmap: &bitmap, rowBytes: modulesWide, bounds: extent, format: .R8, colorSpace: nil)

        let isModuleSet: (Int, Int) -> Bool = { x, y in
            guard x >= 0, x < modulesWide, y >= 0, y < modulesHigh else { return false }
            return bitmap[y * modulesWide + x] < 128
        }

        let size = Int(targetSize)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)

        // Arka plan: Yüksek kontrastlı, temiz ışık plakası (Quiet Zone ile)
        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let quietZone = 4.0
        let totalUnits = Double(modulesWide) + (quietZone * 2.0)
        let modulePitch = Double(size) / totalUnits
        let startX = quietZone * modulePitch
        let startY = quietZone * modulePitch

        func isFinder(x: Int, y: Int) -> Bool {
            let topLeft = (x < 7 && y < 7)
            let topRight = (x >= modulesWide - 7 && y < 7)
            let bottomLeft = (x < 7 && y >= modulesHigh - 7)
            return topLeft || topRight || bottomLeft
        }

        // Koyu renkli ışık noktaları (Derin gece mavisi / siyah tonu)
        let dotColor = CGColor(red: 0.04, green: 0.07, blue: 0.15, alpha: 1.0)

        // 1. Köşe Bulucular (Finder Patterns): Standart 1:1:3:1:1 oranlı hassas kareler
        // Donanımsal tarayıcıların (AVFoundation ve iOS Kamera) milisaniyeler içinde yakalaması için şarttır!
        func drawFinder(originX: Int, originY: Int) {
            let fx = CGFloat(startX + Double(originX) * modulePitch)
            let fy = CGFloat(startY + Double(originY) * modulePitch)
            let fSize = CGFloat(7.0 * modulePitch)

            // Dış 7x7 koyu kare
            ctx.setFillColor(dotColor)
            ctx.fill(CGRect(x: fx, y: fy, width: fSize, height: fSize))

            // İç 5x5 beyaz boşluk
            let gapSize = CGFloat(5.0 * modulePitch)
            let gapOffset = CGFloat(modulePitch)
            ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            ctx.fill(CGRect(x: fx + gapOffset, y: fy + gapOffset, width: gapSize, height: gapSize))

            // Merkez 3x3 koyu çekirdek
            let coreSize = CGFloat(3.0 * modulePitch)
            let coreOffset = CGFloat(2.0 * modulePitch)
            ctx.setFillColor(dotColor)
            ctx.fill(CGRect(x: fx + coreOffset, y: fy + coreOffset, width: coreSize, height: coreSize))
        }

        drawFinder(originX: 0, originY: 0)
        drawFinder(originX: modulesWide - 7, originY: 0)
        drawFinder(originX: 0, originY: modulesHigh - 7)

        // 2. Veri Modülleri: Parıldayan dairesel ışık noktaları (Dot-Matrix)
        let dotRadius = CGFloat(modulePitch * 0.46)
        ctx.setFillColor(dotColor)

        for y in 0..<modulesHigh {
            for x in 0..<modulesWide {
                if isFinder(x: x, y: y) { continue }
                if isModuleSet(x, y) {
                    let cx = CGFloat(startX + (Double(x) + 0.5) * modulePitch)
                    let cy = CGFloat(startY + (Double(y) + 0.5) * modulePitch)
                    let dotRect = CGRect(x: cx - dotRadius, y: cy - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
                    ctx.fillEllipse(in: dotRect)
                }
            }
        }

        return ctx.makeImage()
    }
}
