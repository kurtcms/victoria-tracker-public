// Reproducible native vector artwork, rasterized for the iOS AppIcon asset.
// Run from the repository root with the Xcode Swift toolchain.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
  bytesPerRow: size * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.setFillColor(CGColor(srgbRed: 1, green: 45.0 / 255, blue: 85.0 / 255, alpha: 1))
context.fillEllipse(in: CGRect(x: 104, y: 104, width: 816, height: 816))

// Original vector heart, matching the login mark's white-heart/pink-circle design.
// iOS supplies the outer app-icon corner mask.
let heart = CGMutablePath()
heart.move(to: CGPoint(x: 512, y: 225))
heart.addCurve(to: CGPoint(x: 203, y: 597), control1: CGPoint(x: 455, y: 280), control2: CGPoint(x: 203, y: 450))
heart.addCurve(to: CGPoint(x: 512, y: 711), control1: CGPoint(x: 203, y: 796), control2: CGPoint(x: 405, y: 834))
heart.addCurve(to: CGPoint(x: 821, y: 597), control1: CGPoint(x: 619, y: 834), control2: CGPoint(x: 821, y: 796))
heart.addCurve(to: CGPoint(x: 512, y: 225), control1: CGPoint(x: 821, y: 450), control2: CGPoint(x: 569, y: 280))
heart.closeSubpath()
context.saveGState()
context.translateBy(x: 512, y: 512)
context.scaleBy(x: 0.72, y: 0.72)
context.translateBy(x: -512, y: -512)
context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
context.addPath(heart)
context.fillPath()
context.restoreGState()
let output = URL(fileURLWithPath: "ios/VictoriaTracker/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not save app icon") }
print("Generated opaque 1024px AppIcon.png")
