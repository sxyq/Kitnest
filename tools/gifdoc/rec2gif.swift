import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// rec2gif in.mov out.gif [options]
//   --crop x,y,w,h      crop rect in POINTS (screen coords, origin top-left)
//   --width 1000        output width in pixels
//   --fps 12            frame rate
//   --start 0.0         start time (s)
//   --end 6.0           end time (s)
//   --scale 2           points→pixels factor (2 for Retina)
//   --quality 1|2       1 = per-frame palette (default), 2 = global palette (smaller)

struct Opts {
    var input = ""
    var output = ""
    var crop: CGRect?
    var width: Int = 1000
    var fps: Double = 12
    var start: Double = 0
    var end: Double = 0
    var scale: Double = 2
    var mode = 1
    var framesDir = ""
}

func parse() -> Opts {
    var o = Opts()
    let a = CommandLine.arguments
    var i = 1
    var positional: [String] = []
    while i < a.count {
        let s = a[i]
        switch s {
        case "--crop":
            i += 1
            let p = a[i].split(separator: ",").map { Double($0)! }
            o.crop = CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
        case "--width": i += 1; o.width = Int(a[i])!
        case "--fps": i += 1; o.fps = Double(a[i])!
        case "--start": i += 1; o.start = Double(a[i])!
        case "--end": i += 1; o.end = Double(a[i])!
        case "--scale": i += 1; o.scale = Double(a[i])!
        case "--quality": i += 1; o.mode = Int(a[i])!
        case "--frames": i += 1; o.framesDir = a[i]
        default: positional.append(s)
        }
        i += 1
    }
    o.input = positional[0]
    o.output = positional[1]
    return o
}

let o = parse()
let asset = AVURLAsset(url: URL(fileURLWithPath: o.input))
guard let track = asset.tracks(withMediaType: .video).first else {
    print("no video track"); exit(1)
}
let dur = CMTimeGetSeconds(asset.duration)
let endT = o.end > 0 ? min(o.end, dur) : dur
print("duration \(String(format: "%.2f", dur))s → \(String(format: "%.2f", endT - o.start))s window")

let reader = try AVAssetReader(asset: asset)
let settings: [String: Any] = [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
]
let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
out.alwaysCopiesSampleData = false
reader.add(out)
reader.startReading()

let srcW = track.naturalSize.width, srcH = track.naturalSize.height
// crop: points → pixels, convert from top-left screen coords to AVFrame coords (also top-left)
var cropPx = CGRect(x: 0, y: 0, width: srcW, height: srcH)
if let c = o.crop {
    cropPx = CGRect(x: c.origin.x * o.scale, y: c.origin.y * o.scale,
                    width: c.width * o.scale, height: c.height * o.scale)
}
cropPx = cropPx.intersection(CGRect(x: 0, y: 0, width: srcW, height: srcH)).integral
let outW = o.width
let outH = Int((cropPx.height * CGFloat(outW) / cropPx.width).rounded())
print("src \(Int(srcW))×\(Int(srcH))  crop \(Int(cropPx.width))×\(Int(cropPx.height))  out \(outW)×\(outH)")

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else {
    print("ctx fail"); exit(1)
}
ctx.interpolationQuality = .high

var frames: [CGImage] = []
var nextTime = o.start
var lastKept = -1.0
let interval = 1.0 / o.fps

while let sb = out.copyNextSampleBuffer() {
    let t = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
    if t + 1e-6 < o.start { continue }
    if t > endT { break }
    guard t >= nextTime - 1e-6 else { continue }
    guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
    // avoid duplicate timestamps producing duplicate frames
    if abs(t - lastKept) < interval * 0.5 { continue }
    lastKept = t
    nextTime += interval

    var img: CGImage?
    VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &img)
    guard let cg = img else { continue }
    let cropped = cg.cropping(to: cropPx) ?? cg
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: outW, height: outH))
    if let frame = ctx.makeImage() { frames.append(frame) }
}

print("frames: \(frames.count)")

// Check orientation: if the first frame is upside down, flip all.
func sampleTopIsLight(_ img: CGImage) -> Bool {
    // not used; orientation handled by drawing with CGImage coordinate convention
    return true
}
_ = sampleTopIsLight

if !o.framesDir.isEmpty {
    try? FileManager.default.createDirectory(atPath: o.framesDir, withIntermediateDirectories: true)
    for (i, f) in frames.enumerated() {
        let rep = NSBitmapImageRep(cgImage: f)
        guard let d = rep.representation(using: .png, properties: [:]) else { continue }
        let name = String(format: "%@/%04d.png", o.framesDir, i)
        try? d.write(to: URL(fileURLWithPath: name))
    }
    print("WROTE \(frames.count) frames → \(o.framesDir)")
    exit(0)
}

let fileURL = URL(fileURLWithPath: o.output)
guard let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.gif.identifier as CFString,
                                                 frames.count, nil) else {
    print("gif dest fail"); exit(1)
}
let gifProps: [String: Any] = [
    kCGImagePropertyGIFDictionary as String: [
        kCGImagePropertyGIFLoopCount as String: 0
    ]
]
CGImageDestinationSetProperties(dest, gifProps as CFDictionary)
let delay = 1.0 / o.fps
for img in frames {
    let frameProps: [String: Any] = [
        kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFDelayTime as String: delay,
            kCGImagePropertyGIFUnclampedDelayTime as String: delay
        ]
    ]
    CGImageDestinationAddImage(dest, img, frameProps as CFDictionary)
}
if CGImageDestinationFinalize(dest) {
    let attrs = try? FileManager.default.attributesOfItem(atPath: o.output)
    let size = (attrs?[.size] as? Int) ?? 0
    print("OK \(o.output) \(size / 1024) KB")
} else {
    print("finalize failed")
}
