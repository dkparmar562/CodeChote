#!/usr/bin/env swift
// Generates the app icon (1024x1024) into the asset catalog.
//   swift scripts/make-icon.swift
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("context") }

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// Background: deep indigo at the bottom-left to vivid violet-blue at the top-right.
let gradient = CGGradient(colorsSpace: space, colors: [color(0x0E1030), color(0x2B2FA8), color(0x7B5CFF)] as CFArray, locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size, y: size), options: [])

// Soft glow behind the glyph.
let glow = CGGradient(colorsSpace: space, colors: [color(0xA9B6FF, 0.40), color(0xA9B6FF, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 470, y: 560), startRadius: 0, endCenter: CGPoint(x: 470, y: 560), endRadius: 520, options: [])

// Terminal prompt: a chevron and a cursor bar.
ctx.setStrokeColor(color(0xFFFFFF))
ctx.setLineWidth(96)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.beginPath()
ctx.move(to: CGPoint(x: 300, y: 690))
ctx.addLine(to: CGPoint(x: 520, y: 512))
ctx.addLine(to: CGPoint(x: 300, y: 334))
ctx.strokePath()

ctx.setLineWidth(96)
ctx.beginPath()
ctx.move(to: CGPoint(x: 590, y: 334))
ctx.addLine(to: CGPoint(x: 770, y: 334))
ctx.strokePath()

// A faint top highlight, like light catching glass.
let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: size * 0.55), options: [])

guard let image = ctx.makeImage() else { fatalError("image") }
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let dir = root.appendingPathComponent("ios/Codechote/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
try png.write(to: dir.appendingPathComponent("icon-1024.png"))
try """
{
  "images" : [
    { "filename" : "icon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""".write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try """
{ "info" : { "author" : "xcode", "version" : 1 } }
""".write(to: dir.deletingLastPathComponent().appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("wrote \(dir.path)")
