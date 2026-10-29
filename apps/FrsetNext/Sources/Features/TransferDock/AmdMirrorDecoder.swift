// AmdMirrorDecoder.swift — H.264 Annex-B → CMSampleBuffer（AVSampleBufferVideoRenderer 解码渲染）
//
// 手机端 MirrorServerMain 输出 Annex-B 裸流（csd1=SPS csd2=PPS，帧含 00 00 00 01 start code）。
// 本类负责：Annex-B → AVCC（长度前缀）→ avcC atom → CMVideoFormatDescription →
// CMSampleBuffer，交给 AVSampleBufferVideoRenderer 解码（与 UI 的 AVSampleBufferDisplayLayer
// 同一通道，frset 集成时 renderer 可直连 layer）。
//
// 注：不直接用 VTDecompressionSession——实测 Swift overlay 的
// VTDecompressionSessionDecodeFrame(completionHandler:) 输出回调不可靠（2026-10-29）。

import Foundation
import CoreMedia
import AVFoundation

final class AmdMirrorDecoder {

    private(set) var format: CMVideoFormatDescription?
    private(set) var sampleBuffers = 0
    private(set) var sampleErrors = 0
    private var debugEnabled = ProcessInfo.processInfo.environment["AMD_DEBUG"] != nil

    /// 解码队列回调（调用方 enqueue 到 AVSampleBufferVideoRenderer / DisplayLayer）
    var onSampleBuffer: ((CMSampleBuffer, Bool) -> Void)?

    /// 用 CSD 建立格式描述
    func configure(width: Int, height: Int, sps: Data, pps: Data) -> Bool {
        teardown()
        // 去掉 Annex-B start code，得到裸 NAL
        guard let spsNal = Self.stripStartCode(sps), let ppsNal = Self.stripStartCode(pps),
              spsNal.count >= 4, ppsNal.count >= 2 else { return false }
        let spsBytes = [UInt8](spsNal)
        var avcC = Data([1])                                             // configurationVersion
        avcC.append(contentsOf: [spsBytes[1], spsBytes[2], spsBytes[3]]) // profile/compat/level
        avcC.append(0xFF)                                                // 6bit reserved + lengthSizeMinusOne=3
        avcC.append(0xE1)                                                // 3bit reserved + 1 SPS
        var l = UInt16(spsNal.count).bigEndian
        withUnsafeBytes(of: &l) { avcC.append(contentsOf: $0) }
        avcC.append(spsNal)
        avcC.append(1)                                                   // 1 PPS
        l = UInt16(ppsNal.count).bigEndian
        withUnsafeBytes(of: &l) { avcC.append(contentsOf: $0) }
        avcC.append(ppsNal)

        let ext: CFDictionary = ["SampleDescriptionExtensionAtoms": ["avcC": avcC]] as CFDictionary
        var fmt: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: Int32(width), height: Int32(height),
            extensions: ext,
            formatDescriptionOut: &fmt)
        guard status == noErr, let formatDesc = fmt else { return false }
        format = formatDesc
        return true
    }

    /// 一帧 Annex-B 数据 → CMSampleBuffer
    func decode(_ annexB: Data, ptsUs: Int64, keyframe: Bool) {
        guard let format else { return }
        let avcc = Self.annexBToAVCC(annexB)
        guard !avcc.isEmpty else { sampleErrors += 1; return }
        var block: CMBlockBuffer?
        avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            let c = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: avcc.count, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
            guard c == kCMBlockBufferNoErr, let blk = block else { return }
            let rep = CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blk, offsetIntoDestination: 0, dataLength: avcc.count)
            if rep != kCMBlockBufferNoErr { block = nil }
        }
        guard let blockBuffer = block else { sampleErrors += 1; return }
        var sampleSize = avcc.count
        var sampleBuffer: CMSampleBuffer?
        var timings = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30), // 有效 duration（renderer 拒收 invalid）
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsUs), timescale: 1_000_000),
            decodeTimeStamp: CMTime.invalid)
        let s = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timings,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard s == noErr, let sb = sampleBuffer else { sampleErrors += 1; return }
        if keyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) {
            if let dict = unsafeBitCast(attachments, to: NSArray.self).firstObject as? NSMutableDictionary {
                dict[kCMSampleAttachmentKey_DependsOnOthers] = false
                dict[kCMSampleAttachmentKey_DisplayImmediately] = true
            }
        }
        sampleBuffers += 1
        onSampleBuffer?(sb, keyframe)
    }

    func teardown() {
        format = nil
    }

    // MARK: - Annex-B 工具

    /// 去掉起始 start code（00 00 00 01 或 00 00 01）
    static func stripStartCode(_ d: Data) -> Data? {
        let b = [UInt8](d)
        if b.count >= 4, b[0] == 0, b[1] == 0, b[2] == 0, b[3] == 1 {
            return Data(b[4...])
        }
        if b.count >= 3, b[0] == 0, b[1] == 0, b[2] == 1 {
            return Data(b[3...])
        }
        return d.isEmpty ? nil : d
    }

    /// Annex-B → AVCC：把每个 start code 换成 4 字节大端长度
    static func annexBToAVCC(_ data: Data) -> Data {
        let b = [UInt8](data)
        var out = Data(capacity: b.count + 64)
        var i = 0
        var nalStart: Int? = nil
        func flush(_ end: Int) {
            guard let s = nalStart, end > s else { return }
            var len = UInt32(end - s).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(contentsOf: b[s..<end])
        }
        while i + 2 < b.count {
            if b[i] == 0, b[i+1] == 0 {
                if b[i+2] == 1 {
                    flush(i)
                    nalStart = i + 3
                    i += 3
                    continue
                } else if i + 3 < b.count, b[i+2] == 0, b[i+3] == 1 {
                    flush(i)
                    nalStart = i + 4
                    i += 4
                    continue
                }
            }
            i += 1
        }
        flush(b.count)
        return out
    }
}
