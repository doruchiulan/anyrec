#!/usr/bin/env swift
// Draws the app icon (design: "AnyRec app icon", default appearance) into an .iconset.
// Usage: scripts/make-icon.swift <out.iconset>
// At 32 px and below the waveform drops and the ring thickens, as the design specifies.
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func render(_ px: Int) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(px) / 1024
    // Design coordinates are 1024 with y down; flip so they can be used as written.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: scale, y: -scale)

    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -max(1, 1024 * 0.03 / 4) * 3), blur: 1024 * 0.05 / 1.2, color: color(0, 0.22))
    ctx.addPath(path)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xE4E4EA)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.restoreGState()

    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(0, 0.06))
    ctx.setLineWidth(4)
    ctx.strokePath()

    let small = px <= 32
    if !small {
        ctx.setFillColor(color(0x0A84FF))
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (152, 477, 70), (192, 437, 150), (232, 407, 210), (272, 457, 110),
            (730, 457, 110), (770, 407, 210), (810, 437, 150), (850, 477, 70),
        ]
        for (x, y, h) in bars {
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: 22, height: h), cornerWidth: 11, cornerHeight: 11, transform: nil))
            ctx.fillPath()
        }
    }

    let ringRadius: CGFloat = small ? 230 : 190, ringWidth: CGFloat = small ? 70 : 40
    ctx.setStrokeColor(color(0x2C2C2E))
    ctx.setLineWidth(ringWidth)
    ctx.addArc(center: CGPoint(x: 512, y: 512), radius: ringRadius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()

    let dotRadius: CGFloat = small ? 130 : 118
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: 512 - dotRadius, y: 512 - dotRadius, width: dotRadius * 2, height: dotRadius * 2))
    ctx.clip()
    let dot = CGGradient(colorsSpace: space, colors: [color(0xFF6A5C), color(0xD70015)] as CFArray, locations: [0, 1])!
    let centre = CGPoint(x: 512 - dotRadius + dotRadius * 2 * 0.4, y: 512 - dotRadius + dotRadius * 2 * 0.35)
    ctx.drawRadialGradient(dot, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: dotRadius * 2 * 0.75, options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
