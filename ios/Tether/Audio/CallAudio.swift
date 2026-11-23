import AVFoundation
import Foundation
import os
@_spi(TetherApp) import TetherCore

/// 20 ms mono voice codec.
protocol VoiceCoder: AnyObject {
    var id: AudioFrame.Codec { get }
    var rate: Double { get }
    func encode(_ pcm: [Int16]) -> Data?
    func decode(_ data: Data) -> [Int16]
    /// The codec's own concealment for one lost 20 ms frame (nil: none).
    func conceal() -> [Int16]?
}

extension VoiceCoder { func conceal() -> [Int16]? { nil } }

final class PcmuCoder: VoiceCoder {
    let id = AudioFrame.Codec.pcmu
    let rate = 8000.0
    func encode(_ pcm: [Int16]) -> Data? { G711.encode(pcm) }
    func decode(_ data: Data) -> [Int16] { G711.decode(data) }
}

/// Opus through AudioToolbox (raw RFC 6716 packets, interoperable with Android's MediaCodec Opus).
final class OpusCoder: VoiceCoder {
    let id = AudioFrame.Codec.opus
    let rate: Double
    private let pcmFormat: AVAudioFormat
    private let opusFormat: AVAudioFormat
    private let encoder: AVAudioConverter
    private let decoder: AVAudioConverter
    /// libopus decoder when available: the same packets, plus packet-loss concealment that continues the voice
    /// (AudioToolbox has none). AudioToolbox decodes only if libopus cannot start.
    private let lib: LibOpusDecoder?

    init?(rate: Double = 16000, bitrate: Int = 32000) {
        self.rate = rate
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true) else { return nil }
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: UInt32(rate / 50), mBytesPerFrame: 0, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 0, mReserved: 0)
        guard let opus = AVAudioFormat(streamDescription: &asbd),
              let enc = AVAudioConverter(from: pcm, to: opus),
              let dec = AVAudioConverter(from: opus, to: pcm) else { return nil }
        enc.bitRate = bitrate
        pcmFormat = pcm; opusFormat = opus; encoder = enc; decoder = dec
        lib = LibOpusDecoder(rate: Int(rate))
    }

    func encode(_ pcm: [Int16]) -> Data? {
        guard !pcm.isEmpty, let buf = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(pcm.count)) else { return nil }
        buf.frameLength = AVAudioFrameCount(pcm.count)
        pcm.withUnsafeBufferPointer { buf.int16ChannelData![0].update(from: $0.baseAddress!, count: pcm.count) }
        let out = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 2, maximumPacketSize: 1500)
        var fed = false
        var err: NSError?
        _ = encoder.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        guard out.packetCount > 0, let desc = out.packetDescriptions?[0] else { return nil }
        return Data(bytes: out.data.advanced(by: Int(desc.mStartOffset)), count: Int(desc.mDataByteSize))
    }

    func decode(_ data: Data) -> [Int16] {
        guard !data.isEmpty else { return [] }
        if let lib { return lib.decode(data) }
        let cb = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 1, maximumPacketSize: max(1, data.count))
        data.withUnsafeBytes { cb.data.copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        cb.packetDescriptions?[0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                 mDataByteSize: UInt32(data.count))
        cb.packetCount = 1
        cb.byteLength = UInt32(data.count)
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(rate / 50 * 3)) else { return [] }
        var fed = false
        var err: NSError?
        _ = decoder.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return cb
        }
        return Array(UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
    }
}

extension OpusCoder {
    func conceal() -> [Int16]? { lib.map { $0.conceal(samples: Int(rate / 50)) }.flatMap { $0.isEmpty ? nil : $0 } }
}

/// Two-way call audio. The engine starts when CallKit activates the audio session:
/// mic → voice processing (echo cancellation) → sink node → codec → link, and
/// link → codec → playout buffer → source node → speaker. Until the far end is heard on an
/// outgoing call, a local ringback tone plays.
final class CallAudio: @unchecked Sendable {
    static let supportedCodecs: [String] = OpusCoder() != nil ? ["opus", "pcmu"] : ["pcmu"]
    private static weak var current: CallAudio?

    private unowned let model: AppModel
    private let link: TetherLink
    private let q = DispatchQueue(label: "tether.audio", qos: .userInteractive)
    private var engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var sink: AVAudioSinkNode?
    private var coder: VoiceCoder?
    private var remote: AudioStart?
    private var sessionActive = false
    private var running = false
    private var playout = PlayoutBuffer(rate: 16000)
    private var playRate = 16000.0
    private var captureConverter: AVAudioConverter?
    private var captureRing = SampleRing(capacity: 48000)
    private var captureMono: AVAudioFormat?
    private var pump: DispatchSourceTimer?
    private var routeObserver: NSObjectProtocol?
    private var sessionRouteObserver: NSObjectProtocol?
    /// The I/O formats the running engine was built with (a hands-free route changes them).
    private var builtFormat: EngineFormat?
    private var rebuildRetries = 0
    private var captureFormat: AVAudioFormat?
    private var captureAcc: [Int16] = []
    private var seq: UInt16 = 0
    private var lastSeq: UInt16?
    private var flagsUnfair = os_unfair_lock()
    /// Flags shared with the real-time render thread: an unfair lock held for a few instructions (no NSLock there).
    private func flags<T>(_ body: () -> T) -> T { os_unfair_lock_lock(&flagsUnfair); defer { os_unfair_lock_unlock(&flagsUnfair) }; return body() }
    private var _muted = false
    private var _ringback = false
    private var ringPhase = 0.0
    private var ringClock = 0
    private var heardRemote = false

    // Measurements (logged at stop, shown in the Link tab).
    private(set) var stats = Stats()
    struct Stats { var ioBufferMs = 0.0; var inputLatencyMs = 0.0; var outputLatencyMs = 0.0; var playoutMs = 0.0
        var underruns = 0; var trimmedMs = 0.0; var lost = 0
        /// Mean playout delay the listener had (the buffer's level), and quiet audio added to reach the target.
        var delayMs = 0.0; var addedMs = 0.0
        /// Frame arrival spacing over the link: mean |gap − 20 ms| and the worst gap seen (BLE jitter).
        var jitterMs = 0.0; var worstGapMs = 0.0; var frames = 0 }
    private var lastArrival: UInt64 = 0
    private var jitterSum = 0.0
    /// Debug (-TetherEcho): send every received frame straight back with the same sequence number instead of
    /// the microphone, so the Android phone can time the whole link round trip (its encode → BLE → our decode/encode → BLE → its decode).
    static let echoTest = ProcessInfo.processInfo.arguments.contains("-TetherEcho")
    /// Debug (-TetherAudioTrace): every 2 s of a call, one console line with the playout's level, target and arrival spread.
    static let trace = ProcessInfo.processInfo.arguments.contains("-TetherAudioTrace")
    private var pumps = 0

    init(model: AppModel, link: TetherLink) {
        self.model = model
        self.link = link
        CallAudio.current = self
    }

    var muted: Bool {
        get { flags { _muted } }
        set { flags { _muted = newValue } }
    }

    /// Local ringback while an outgoing call is dialing; cleared when the call connects or real audio arrives.
    var ringback: Bool {
        get { flags { _ringback } }
        set { flags { _ringback = newValue; if newValue { heardRemote = false } } }
    }
    /// Our ringback should sound now (dialing, and nothing audible from the far end yet).
    var ringbackAudible: Bool { flags { _ringback && !heardRemote } }

    static func configureSession() {
        let s = AVAudioSession.sharedInstance()
        // Hands-free (HFP) Bluetooth and car kits for calls; A2DP has no microphone. No .defaultToSpeaker: the
        // receiver is the default and the speaker is an override the user picks.
        do { try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth]) }
        catch { NSLog("[audio] category: %@", "\(error)") }
        try? s.setPreferredSampleRate(16000)
        try? s.setPreferredIOBufferDuration(0.01) // 10 ms I/O buffer
    }

    /// From the link queue: decode right away (Opus decoding is cheap) and queue PCM for playout. The arrival time is
    /// taken here, not when the audio queue gets to the frame: that queue also encodes the microphone and restarts the
    /// engine, and its delays are not the link's (the playout's arrival statistics are about the link).
    static func incoming(_ f: AudioFrame) {
        guard let c = current else { return }
        let at = DispatchTime.now().uptimeNanoseconds
        c.q.async { c.receive(f, at: at) }
    }

    @MainActor func configure(_ start: AudioStart) {
        q.async {
            self.remote = start
            self.coder = start.codec == "opus" ? (OpusCoder(rate: Double(start.rate), bitrate: start.bitrate ?? 32000) ?? PcmuCoder()) : PcmuCoder()
            self.lastSeq = nil
            if self.sessionActive {
                if self.running && (self.coder?.rate ?? 16000) != self.playRate { self.stopLocked() }
                self.startLocked()
                self.observeSessionRoute()   // a next call on a still-active session: stop() removed it
            }
        }
    }

    @MainActor func sessionActivated() {
        link.measureRoundTrip()
        q.async {
            self.noVoiceProcessing = false   // try echo cancellation again on every call
            self.sessionActive = true
            self.rebuildRetries = 0
            self.startLocked()
            self.observeSessionRoute()
        }
    }

    @MainActor func sessionDeactivated() {
        q.async { self.sessionActive = false; self.unobserveSessionRoute(); self.stopLocked() }
    }

    @MainActor func remoteStopped() {
        q.async { self.coder = nil; self.remote = nil }
    }

    @MainActor func stop() {
        q.async { self.unobserveSessionRoute(); self.stopLocked(); self.coder = nil; self.remote = nil; self.ringback = false; self.muted = false; self.seq = 0 }
    }

    /// Voice processing (echo cancellation) could not start with the current devices: run without it.
    private var noVoiceProcessing = false

    /// `rebuild`: a route change on a running call; the playout buffer, ringback and statistics carry over so the
    /// far end keeps playing after the switch (only the graph, its formats and converters are new).
    private func startLocked(rebuild: Bool = false) {
        guard !running else { return }
        let rate = coder?.rate ?? 16000
        let input = engine.inputNode
        do { try input.setVoiceProcessingEnabled(!noVoiceProcessing) } catch { NSLog("[audio] voice processing: %@", "\(error)") }
        let inFormat = input.outputFormat(forBus: 0)
        // Touch the output node before the main mixer exists (the I/O layout this engine was tuned with).
        _ = engine.outputNode.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let codecFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
              let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false) else {
            NSLog("[audio] no input format"); return
        }
        let keepPlayout = rebuild && playRate == rate
        playRate = rate
        if !keepPlayout { playout = PlayoutBuffer(rate: rate) }
        captureFormat = codecFormat
        guard let mono = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: 1) else { return }
        captureMono = mono
        captureConverter = AVAudioConverter(from: mono, to: codecFormat)
        captureRing = SampleRing(capacity: Int(inFormat.sampleRate))

        // Playback: the render thread pulls straight from the playout buffer (no scheduled backlog).
        let buffer = playout
        let src = AVAudioSourceNode(format: playFormat) { [weak self] _, _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            guard let out = list.first?.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let n = Int(frameCount)
            buffer.pull(into: out, count: n)
            // While dialing, the downlink is often silence (on VoLTE the ringback is played by the phone itself,
            // not sent): play our own ringback until real audio (network ringback, the answer) is heard.
            if let self, self.ringbackAudible { self.fillRingback(out, count: n, rate: rate) }
            return noErr
        }
        // Capture: the sink node gets each I/O buffer (≈10 ms). It only copies channel 0 into a ring;
        // a 10 ms pump on the audio queue converts and encodes (nothing allocates on the real-time thread).
        let ring = captureRing
        let interleaved = inFormat.isInterleaved
        let channels = Int(inFormat.channelCount)
        let snk = AVAudioSinkNode { _, frameCount, abl -> OSStatus in
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
            guard let first = list.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.write(data, Int(frameCount), stride: interleaved ? channels : 1)
            return noErr
        }
        engine.attach(src)
        engine.attach(snk)
        engine.connect(input, to: snk, format: inFormat)
        engine.connect(src, to: engine.mainMixerNode, format: playFormat)
        source = src
        sink = snk
        engine.prepare()
        do {
            try engine.start()
        } catch {
            NSLog("[audio] engine start failed (voice processing %@): %@", noVoiceProcessing ? "off" : "on", "\(error)")
            teardownNodes()
            if !noVoiceProcessing {
                // The output unit would not initialize with voice processing: retry plainly.
                noVoiceProcessing = true
                engine = AVAudioEngine()
                startLocked(rebuild: rebuild)
            }
            return
        }
        captureAcc.removeAll()
        // `seq` keeps counting across engine restarts (route changes): the Android phone drops frames whose number goes back.
        if !rebuild { lastArrival = 0; jitterSum = 0; stats = Stats() }
        // Read the same way as in routeEvent (the session's values): the engine nodes report other channel counts with
        // voice processing, and the mismatch made every route event look like a format change.
        builtFormat = Self.sessionFormat()
        rebuildRetries = 0
        running = true
        let p = DispatchSource.makeTimerSource(queue: q)
        p.schedule(deadline: .now() + 0.005, repeating: 0.005, leeway: .milliseconds(1))   // 5 ms: frames leave ≤ 5 ms after capture
        p.setEventHandler { [weak self] in self?.drainCapture() }
        p.resume()
        pump = p
        // Speaker / headset / car route changes reconfigure the engine and stop it: build a fresh one.
        routeObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.q.async { self.routeEvent(configurationChanged: true) }
        }
        let s = AVAudioSession.sharedInstance()
        stats.ioBufferMs = s.ioBufferDuration * 1000
        stats.inputLatencyMs = s.inputLatency * 1000
        stats.outputLatencyMs = s.outputLatency * 1000
        NSLog("[audio] started %@ @ %.0f Hz; io %.1f ms, in %.1f ms, out %.1f ms, voice processing %@, input %.0f Hz × %d",
              remote?.codec ?? "(waiting for codec)", rate, stats.ioBufferMs, stats.inputLatencyMs, stats.outputLatencyMs,
              noVoiceProcessing ? "off" : "on", inFormat.sampleRate, Int(inFormat.channelCount))
    }

    /// Route change or engine configuration change while a call's session is active (TetherCore decides).
    private func routeEvent(configurationChanged: Bool) {
        guard sessionRouteObserver != nil || configurationChanged else { return }   // not after stop()
        let now = Self.sessionFormat()
        let t = DispatchTime.now().uptimeNanoseconds
        rebuildTimes.removeAll { t - $0 > 3_000_000_000 }
        switch EngineDecision.onRouteEvent(sessionActive: sessionActive, running: running, configurationChanged: configurationChanged,
                                           built: builtFormat, now: now, engineRunning: running && engine.isRunning,
                                           recentRebuilds: rebuildTimes.count) {
        case .keep: return
        case .rebuild:
            rebuildTimes.append(t)
            NSLog("[audio] %@ changed: rebuilding the engine (%.0f Hz in)", configurationChanged ? "configuration" : "route", now.inputRate)
            stopLocked(rebuild: true)
            engine = AVAudioEngine()   // a fresh graph: the old one keeps stale I/O formats after a hands-free switch
            startLocked(rebuild: true)
            if !running { retryLater() }
        case .restart:
            do { try engine.start(); NSLog("[audio] configuration changed, same formats: engine started again") }
            catch {
                NSLog("[audio] engine restart failed (%@): rebuilding", "\(error)")
                rebuildTimes.append(t)
                stopLocked(rebuild: true); engine = AVAudioEngine(); startLocked(rebuild: true)
                if !running { retryLater() }
            }
        case .retryLater:
            if running { stopLocked(rebuild: true) }
            retryLater()
        }
    }

    /// When the engine was rebuilt for a route event in the last 3 s (a loop guard, see EngineDecision).
    private var rebuildTimes: [UInt64] = []

    /// The audio session's current formats, as the engine decisions compare them.
    private static func sessionFormat() -> EngineFormat {
        let s = AVAudioSession.sharedInstance()
        return EngineFormat(inputRate: s.isInputAvailable ? s.sampleRate : 0, inputChannels: s.isInputAvailable ? max(1, s.inputNumberOfChannels) : 0,
                            outputRate: s.sampleRate, outputChannels: s.outputNumberOfChannels)
    }

    /// The new route has no input yet (Bluetooth hands-free takes a moment): try again shortly, ~2 s at most.
    private func retryLater() {
        guard rebuildRetries < 20 else { NSLog("[audio] no usable route after a change"); return }
        rebuildRetries += 1
        q.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            // The call may have ended meanwhile (stop() removes the route observer before CallKit deactivates).
            guard let self, self.sessionActive, !self.running, self.sessionRouteObserver != nil else { return }
            self.routeEvent(configurationChanged: false)
        }
    }

    private func observeSessionRoute() {
        guard sessionRouteObserver == nil else { return }
        sessionRouteObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.q.async { self.routeEvent(configurationChanged: false) }
        }
    }

    private func unobserveSessionRoute() {
        if let o = sessionRouteObserver { NotificationCenter.default.removeObserver(o); sessionRouteObserver = nil }
    }

    private func teardownNodes() {
        if let source { engine.detach(source) }
        if let sink { engine.detach(sink) }
        source = nil; sink = nil
    }

    private func stopLocked(rebuild: Bool = false) {
        guard running else { return }
        running = false
        pump?.cancel(); pump = nil
        if let o = routeObserver { NotificationCenter.default.removeObserver(o); routeObserver = nil }
        engine.stop()
        teardownNodes()
        builtFormat = nil
        if rebuild { return }   // the call goes on: statistics are logged once, at its end
        stats.underruns = playout.underruns
        stats.trimmedMs = Double(playout.trimmed) / playRate * 1000
        stats.playoutMs = Double(playout.target) / playRate * 1000
        stats.delayMs = playout.meanBuffered / playRate * 1000
        stats.addedMs = Double(playout.inserted) / playRate * 1000
        stats.jitterMs = stats.frames > 1 ? jitterSum / Double(stats.frames - 1) : 0
        NSLog("[audio] stopped: playout delay %.0f ms (target %.0f), underruns %d, concealed %.0f ms, trimmed %.0f ms, added %.0f ms, lost %d, frames %d, jitter %.1f ms, worst gap %.0f ms, drift %.0f ppm",
              stats.delayMs, stats.playoutMs, stats.underruns, Double(playout.concealedSamples) / playRate * 1000, stats.trimmedMs, stats.addedMs,
              stats.lost, stats.frames, stats.jitterMs, stats.worstGapMs, playout.driftPpm)
        let snapshot = stats
        let concealedMs = Double(playout.concealedSamples) / playRate * 1000
        let rtt = link.lastRoundTripMs.map { "\($0) ms" } ?? "-"
        // Call statistics in the Link log: what a real call measured on this iPhone.
        let spreadMs = Double(playout.jitterFloor) / playRate * 1000
        if playout.concealedFrames > 0 { NSLog("[audio] %d lost frames filled by Opus concealment", playout.concealedFrames) }
        LinkJournal.shared.add(String(format: "call audio: link round trip %@, playout delay %.0f ms (target %.0f, arrival spread asks %.0f), concealed %.0f ms, underruns %d, drained %.0f ms, added %.0f ms, lost %d of %d frames, arrival jitter %.1f ms, worst gap %.0f ms, drift %.0f ppm, io %.1f ms, out latency %.1f ms",
                                      rtt, snapshot.delayMs, snapshot.playoutMs, spreadMs, concealedMs, snapshot.underruns, snapshot.trimmedMs, snapshot.addedMs, snapshot.lost,
                                      snapshot.frames, snapshot.jitterMs, snapshot.worstGapMs, playout.driftPpm, snapshot.ioBufferMs, snapshot.outputLatencyMs))
        DispatchQueue.main.async { MainActor.assumeIsolatedCompat { AppModel.shared.lastAudioStats = snapshot } }
    }

    private func receive(_ f: AudioFrame, at now: UInt64) {
        guard running, let coder, f.codec == coder.id else { return }
        var missing = 0
        if let last = lastSeq {
            let gap = Int(Int16(bitPattern: f.seq &- last))
            if gap <= 0 { return }               // late / duplicate: drop
            if gap > 1 { stats.lost += gap - 1; missing = min(gap - 1, 50) }
        }
        lastSeq = f.seq
        if lastArrival != 0 && now > lastArrival {
            let gap = Double(now - lastArrival) / 1e6
            jitterSum += abs(gap - 20)
            stats.worstGapMs = max(stats.worstGapMs, gap)
        }
        lastArrival = now
        stats.frames += 1
        // Frames the Android phone dropped for lateness: the decoder's concealment takes their place (up to two, as the
        // Android phone does for the uplink). It must run before this frame is decoded: concealment continues from the
        // last decoded frame, and the decoder then moves smoothly into this one.
        var filled = 0
        if missing > 0 && missing <= 2 {
            for _ in 0..<missing { if let plc = coder.conceal() { playout.push(plc, at: now, concealed: true); filled += 1 } }
        }
        let pcm = coder.decode(f.payload)
        if Self.echoTest, let back = coder.encode(pcm) {
            link.sendAudio(AudioFrame(codec: coder.id, seq: f.seq, payload: back))
        }
        if ringbackAudible {
            // Network ringback or the answer is audible: stop the local tone.
            let energy = pcm.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, pcm.count))
            if energy.squareRoot() > 300 {
                flags { heardRemote = true; _ringback = false }
                NSLog("[audio] far end audible: local ringback off")
            }
        }
        // Arrival time and lost frames feed the playout's jitter statistics (its target follows the arrival spread).
        playout.push(pcm, at: now, missing: missing - filled)
    }

    private func drainCapture() {
        if Self.trace, running { pumps += 1; if pumps % 400 == 0 { traceLine() } }
        guard running, let coder, let conv = captureConverter, let format = captureFormat, let mono = captureMono else { return }
        let n = captureRing.available
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(captureRing.read(into: buf.floatChannelData![0], n))
        let ratio = format.sampleRate / mono.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * ratio) + 16) else { return }
        var fed = false
        var err: NSError?
        _ = conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buf
        }
        captureAcc.append(contentsOf: UnsafeBufferPointer(start: out.int16ChannelData![0], count: Int(out.frameLength)))
        let frame = Int(coder.rate / 50)
        if Self.echoTest { captureAcc.removeAll(); return }
        let silent = muted
        while captureAcc.count >= frame {
            let chunk = silent ? [Int16](repeating: 0, count: frame) : Array(captureAcc.prefix(frame))
            captureAcc.removeFirst(frame)
            if let payload = coder.encode(chunk) {
                link.sendAudio(AudioFrame(codec: coder.id, seq: seq, payload: payload))
                seq &+= 1
            }
        }
    }

    private func traceLine() {
        let ms = { (s: Int) in Double(s) / self.playRate * 1000 }
        NSLog("[audio] trace: level %.0f ms (mean %.0f), target %.0f, floor %.0f, drained %.0f, added %.0f, concealed %.0f ms; %@",
              ms(playout.buffered), playout.meanBuffered / playRate * 1000, ms(playout.target), ms(playout.jitterFloor),
              ms(playout.trimmed), ms(playout.inserted), ms(playout.concealedSamples), playout.arrivalSummary())
    }

    /// 425 Hz, 1 s on / 4 s off (the ITU-recommended ringback used by Iranian and most European networks).
    private func fillRingback(_ out: UnsafeMutablePointer<Float>, count: Int, rate: Double) {
        for i in 0..<count {
            // 1 s on / 4 s off with 5 ms ramps at each edge (no clicks).
            let pos = ringClock % Int(rate * 5), edge = Int(rate * 0.005)
            let env: Double = pos >= Int(rate) ? 0 : Double(min(pos, Int(rate) - pos, edge)) / Double(edge)
            out[i] = Float(0.12 * env * sin(ringPhase))
            ringPhase += 2 * .pi * 425 / rate
            if ringPhase > 2 * .pi { ringPhase -= 2 * .pi }
            ringClock += 1
        }
    }
}
