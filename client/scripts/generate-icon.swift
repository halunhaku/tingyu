#!/usr/bin/env swift
// Sound Island (A). Geometry mirrors resources/icon.svg and components/icons/brand.svg.
// Run from client/: swift scripts/generate-icon.swift [icon.png] [tray.png]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())
let iconOutput = args.first ?? "resources/icon.png"
let trayOutput = args.count > 1 ? args[1] : "internal/app/tray.png"
let colorSpace = CGColorSpaceCreateDeviceRGB()
func color(_ hex: UInt32) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, 1])!
}
func brand(_ c: CGContext) {
    c.setLineWidth(1.8)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.move(to: CGPoint(x: 9, y: 15))
    c.addLine(to: CGPoint(x: 9, y: 6))
    c.addLine(to: CGPoint(x: 18, y: 4))
    c.addLine(to: CGPoint(x: 18, y: 13))
    c.move(to: CGPoint(x: 9, y: 9))
    c.addLine(to: CGPoint(x: 18, y: 7))
    c.strokePath()
    c.strokeEllipse(in: CGRect(x: 4, y: 13, width: 5, height: 4))
    c.strokeEllipse(in: CGRect(x: 13, y: 11, width: 5, height: 4))
    c.move(to: CGPoint(x: 4, y: 20))
    c.addQuadCurve(to: CGPoint(x: 12, y: 20), control: CGPoint(x: 8, y: 24))
    c.addQuadCurve(to: CGPoint(x: 20, y: 20), control: CGPoint(x: 16, y: 16))
    c.strokePath()
}
func render(size: Int, template: Bool, output: String) throws {
    guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("canvas") }
    c.translateBy(x: 0, y: CGFloat(size))
    c.scaleBy(x: CGFloat(size) / 24, y: -CGFloat(size) / 24)
    c.setAllowsAntialiasing(true)
    c.setShouldAntialias(true)
    if !template {
        c.saveGState()
        c.addPath(CGPath(roundedRect: CGRect(x: 1, y: 1, width: 22, height: 22),
            cornerWidth: 5, cornerHeight: 5, transform: nil))
        c.clip()
        let gradient = CGGradient(colorsSpace: colorSpace,
            colors: [color(0xFF9AA7), color(0xDB354F)] as CFArray, locations: [0, 1])!
        c.drawLinearGradient(gradient, start: CGPoint(x: 1, y: 1),
            end: CGPoint(x: 23, y: 23), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        c.restoreGState()
        c.translateBy(x: 3, y: 3)
        c.scaleBy(x: 0.75, y: 0.75)
    }
    c.setStrokeColor(color(template ? 0x000000 : 0x17171A))
    brand(c)
    guard let image = c.makeImage() else { fatalError("render") }
    let url = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { fatalError("cannot create \(output)") }
    CGImageDestinationAddImage(dst, image, nil)
    guard CGImageDestinationFinalize(dst) else { fatalError("cannot write \(output)") }
}
try render(size: 1024, template: false, output: iconOutput)
try render(size: 32, template: true, output: trayOutput)
