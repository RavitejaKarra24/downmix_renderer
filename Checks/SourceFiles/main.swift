import AudioToolbox
import Darwin
import Foundation
import Synchronization

// Isolated checks for open-file source detection. Fixtures are generated in a private
// temporary directory; no player, device, routing or user file is touched.

private func expect(_ condition: Bool, _ name: String) {
  precondition(condition, "FAIL: \(name)")
}

private let directory = FileManager.default.temporaryDirectory
  .appendingPathComponent("downmix-source-files-\(getpid())", isDirectory: true)

/// Writes one second of a quiet tone through ExtAudioFile. Returns nil when this
/// macOS build has no encoder for the format (reported, not silently passed).
private func makeFixture(
  _ name: String, type: AudioFileTypeID, format: AudioStreamBasicDescription
) -> String? {
  let url = directory.appendingPathComponent(name)
  var fileFormat = format
  var file: ExtAudioFileRef?
  guard
    ExtAudioFileCreateWithURL(
      url as CFURL, type, &fileFormat, nil, AudioFileFlags.eraseFile.rawValue, &file)
      == noErr, let file
  else { return nil }
  defer { ExtAudioFileDispose(file) }
  let channels = format.mChannelsPerFrame
  var client = AudioStreamBasicDescription(
    mSampleRate: format.mSampleRate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 4 * channels, mFramesPerPacket: 1, mBytesPerFrame: 4 * channels,
    mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
  guard
    ExtAudioFileSetProperty(
      file, kExtAudioFileProperty_ClientDataFormat,
      UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client) == noErr
  else { return nil }
  let frames = Int(format.mSampleRate)
  var samples = [Float](repeating: 0, count: frames * Int(channels))
  for frame in 0..<frames {
    let value = 0.1 * sin(Float(frame) * 2 * .pi * 440 / Float(format.mSampleRate))
    for channel in 0..<Int(channels) { samples[frame * Int(channels) + channel] = value }
  }
  let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
    var list = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(
        mNumberChannels: channels, mDataByteSize: UInt32(raw.count), mData: raw.baseAddress))
    return ExtAudioFileWrite(file, UInt32(frames), &list)
  }
  return status == noErr ? url.path : nil
}

private func pcm(_ rate: Double, bits: UInt32, channels: UInt32 = 2, bigEndian: Bool = false)
  -> AudioStreamBasicDescription
{
  let bytes = bits / 8
  return AudioStreamBasicDescription(
    mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
      | (bigEndian ? kAudioFormatFlagIsBigEndian : 0),
    mBytesPerPacket: bytes * channels, mFramesPerPacket: 1, mBytesPerFrame: bytes * channels,
    mChannelsPerFrame: channels, mBitsPerChannel: bits, mReserved: 0)
}

private func compressed(
  _ id: AudioFormatID, _ rate: Double, flags: UInt32 = 0, channels: UInt32 = 2
)
  -> AudioStreamBasicDescription
{
  AudioStreamBasicDescription(
    mSampleRate: rate, mFormatID: id, mFormatFlags: flags, mBytesPerPacket: 0,
    mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0,
    mReserved: 0)
}

private func file(_ path: String, _ offset: Int64, rate: Double, bits: Int? = 24)
  -> SourceFileInspector.OpenFile
{
  .init(
    path: path, offset: offset,
    format: SourceFileFormat(
      fileName: (path as NSString).lastPathComponent, sampleRate: rate, bitDepth: bits,
      channels: 2))
}

// MARK: Candidate filtering and depth flags

expect(SourceFileInspector.isCandidate(path: "/Users/a/Music/x.flac"), "FLAC is a candidate")
expect(SourceFileInspector.isCandidate(path: "/Volumes/NAS/Song.WAV"), "Extension is case-blind")
expect(SourceFileInspector.isCandidate(path: "/Users/a/Movies/film.mp4"), "MP4 is a candidate")
for rejected in [
  "/Applications/Zen.app/Contents/Resources/beep.wav", "/System/Library/Sounds/Ping.aiff",
  "/usr/share/x.mp3", "/Users/a/Library/Caches/x.m4a", "relative/x.flac",
  "/Users/a/Music/cover.jpg", "/Users/a/Music/x.mkv", "/Users/a/Music/x.flac.part",
] {
  expect(!SourceFileInspector.isCandidate(path: rejected), "Rejects \(rejected)")
}
expect(
  SourceFileInspector.bitDepth(
    of: compressed(kAudioFormatFLAC, 96_000, flags: 3), sourceBitDepth: nil)
    == 24, "FLAC flag 3 is 24-bit")
expect(
  SourceFileInspector.bitDepth(
    of: compressed(kAudioFormatAppleLossless, 44_100, flags: 1), sourceBitDepth: nil) == 16,
  "ALAC flag 1 is 16-bit")
expect(
  SourceFileInspector.bitDepth(of: pcm(48_000, bits: 24), sourceBitDepth: nil) == 24,
  "PCM word size")
expect(
  SourceFileInspector.bitDepth(of: compressed(kAudioFormatMPEG4AAC, 44_100), sourceBitDepth: nil)
    == nil, "Lossy has no bit depth")
expect(
  SourceFileInspector.bitDepth(of: compressed(kAudioFormatMPEG4AAC, 44_100), sourceBitDepth: -32)
    == 32, "Float source depth is reported by magnitude")
print("PASS: candidate filtering and source-depth flags")

// MARK: Real headers through the production reader

try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
struct Expected {
  var name: String
  var type: AudioFileTypeID
  var format: AudioStreamBasicDescription
  var rate: Double
  var bits: Int?
  var channels: Int
  var optional = false
}
let fixtures = [
  Expected(
    name: "a.wav", type: kAudioFileWAVEType, format: pcm(44_100, bits: 16), rate: 44_100, bits: 16,
    channels: 2),
  Expected(
    name: "b.wav", type: kAudioFileWAVEType, format: pcm(96_000, bits: 24), rate: 96_000, bits: 24,
    channels: 2),
  Expected(
    name: "c.aiff", type: kAudioFileAIFFType, format: pcm(192_000, bits: 24, bigEndian: true),
    rate: 192_000, bits: 24, channels: 2),
  Expected(
    name: "d.wav", type: kAudioFileWAVEType, format: pcm(48_000, bits: 24, channels: 6),
    rate: 48_000, bits: 24, channels: 6),
  Expected(
    name: "e.flac", type: kAudioFileFLACType,
    format: compressed(kAudioFormatFLAC, 96_000, flags: 3),
    rate: 96_000, bits: 24, channels: 2, optional: true),
  Expected(
    name: "f.m4a", type: kAudioFileM4AType,
    format: compressed(kAudioFormatAppleLossless, 44_100, flags: 1), rate: 44_100, bits: 16,
    channels: 2, optional: true),
  Expected(
    name: "g.m4a", type: kAudioFileM4AType, format: compressed(kAudioFormatMPEG4AAC, 48_000),
    rate: 48_000, bits: nil, channels: 2, optional: true),
]
var verified: [String] = []
for fixture in fixtures {
  guard let path = makeFixture(fixture.name, type: fixture.type, format: fixture.format) else {
    expect(fixture.optional, "PCM fixture \(fixture.name) must be writable")
    print("SKIP: no encoder for \(fixture.name) on this macOS")
    continue
  }
  let read = SourceFileInspector.readFormat(path: path)
  expect(read?.sampleRate == fixture.rate, "\(fixture.name) rate \(String(describing: read))")
  expect(read?.bitDepth == fixture.bits, "\(fixture.name) depth \(String(describing: read))")
  expect(read?.channels == fixture.channels, "\(fixture.name) channels")
  expect(read?.fileName == fixture.name, "\(fixture.name) file name")
  verified.append(fixture.name)
}
let junk = directory.appendingPathComponent("junk.flac")
try Data("not audio".utf8).write(to: junk)
expect(SourceFileInspector.readFormat(path: junk.path) == nil, "Unreadable header yields nothing")
expect(
  SourceFileInspector.readFormat(path: "/nonexistent/x.wav") == nil, "Missing file yields nothing")
print("PASS: production header reader on \(verified.joined(separator: ", "))")

// MARK: Open-file listing of a real process (this one)

let playing = directory.appendingPathComponent("b.wav")
let handle = try FileHandle(forReadingFrom: playing)
_ = try handle.read(upToCount: 4096)
let listed = SourceFileInspector.openFiles(pid: getpid())
let match = listed.first { $0.path.hasSuffix("/b.wav") }
expect(match != nil, "This process's open audio file is listed: \(listed)")
expect(match?.offset == 4096, "Its read position is reported")
expect(SourceFileInspector.openFiles(pid: -1).isEmpty, "Invalid PID lists nothing")
expect(SourceFileInspector.openFiles(pid: 1).isEmpty, "Another user's process lists nothing")
try handle.close()
expect(
  !SourceFileInspector.openFiles(pid: getpid()).contains { $0.path.hasSuffix("/b.wav") },
  "A closed file is no longer listed")
print("PASS: libproc open-file listing, offsets and access limits")

// MARK: Current-track selection

let start = Date(timeIntervalSince1970: 1_800_000_000)
var selection = SourceFileInspector.Selection()
expect(selection.choose([], now: start) == .init(), "Nothing open is nothing")
var choice = selection.choose([file("/m/a.flac", 100, rate: 96_000)], now: start)
expect(choice.format?.sampleRate == 96_000 && !choice.idle, "A single file is the track")
choice = selection.choose([file("/m/a.flac", 900, rate: 96_000)], now: start + 1)
// Gapless preload of a 44.1 kHz next track while the 96 kHz one keeps playing.
choice = selection.choose(
  [file("/m/a.flac", 1800, rate: 96_000), file("/m/b.flac", 8192, rate: 44_100)], now: start + 2)
expect(choice.format?.sampleRate == 96_000, "A preloaded next track does not take over")
choice = selection.choose(
  [file("/m/a.flac", 2700, rate: 96_000), file("/m/b.flac", 8192, rate: 44_100)], now: start + 3)
expect(choice.format?.sampleRate == 96_000, "The track being read stays current")
choice = selection.choose(
  [file("/m/a.flac", 2700, rate: 96_000), file("/m/b.flac", 9000, rate: 44_100)], now: start + 4)
expect(choice.format?.sampleRate == 44_100, "The file now being read becomes current")
choice = selection.choose([file("/m/b.flac", 9900, rate: 44_100)], now: start + 5)
expect(choice.format?.sampleRate == 44_100, "The finished track closing changes nothing")
choice = selection.choose([file("/m/b.flac", 9900, rate: 44_100)], now: start + 16)
expect(choice.idle, "A read position frozen for 10 s is a paused player")
choice = selection.choose([file("/m/b.flac", 10_500, rate: 44_100)], now: start + 17)
expect(!choice.idle, "Reading again is active again")

var fresh = SourceFileInspector.Selection()
choice = fresh.choose(
  [file("/m/x.flac", 0, rate: 96_000), file("/m/y.flac", 0, rate: 44_100)], now: start)
expect(choice.format == nil && choice.ambiguous, "Two disagreeing files with no history hold")
var agreeing = SourceFileInspector.Selection()
choice = agreeing.choose(
  [file("/m/x.flac", 0, rate: 48_000), file("/m/y.flac", 0, rate: 48_000)], now: start)
expect(choice.format?.sampleRate == 48_000, "Agreeing files share their format")
var pread = SourceFileInspector.Selection()
_ = pread.choose([file("/m/p.flac", 0, rate: 96_000)], now: start)
choice = pread.choose([file("/m/p.flac", 0, rate: 96_000)], now: start + 60)
expect(!choice.idle, "Players that never move the position are never called paused")
print("PASS: gapless preload, active-read switch, pause detection and ambiguity")

// MARK: Monitor lifecycle with injected listing

let reports = Mutex<[SourceFileObservation]>([])
let listing = Mutex<[(path: String, offset: Int64)]>([("/m/a.flac", 10)])
let reads = Mutex(0)
let source = AudioPlaybackSource(id: 4242, name: "Fixture", bundleIdentifier: nil)
let monitor = SourceFileMonitor(
  lister: { pid in pid == 4242 ? listing.withLock { $0 } : [] },
  formatReader: { path in
    reads.withLock { $0 += 1 }
    return SourceFileFormat(
      fileName: (path as NSString).lastPathComponent, sampleRate: 96_000, bitDepth: 24,
      channels: 2)
  },
  interval: .milliseconds(20))

func pump(_ seconds: TimeInterval) {
  let until = Date().addingTimeInterval(seconds)
  while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

monitor.start(source: source) { observation in
  dispatchPrecondition(condition: .onQueue(.main))
  reports.withLock { $0.append(observation) }
}
pump(0.2)
expect(
  reports.withLock { $0 } == [
    SourceFileObservation(
      sourcePID: 4242,
      format: SourceFileFormat(fileName: "a.flac", sampleRate: 96_000, bitDepth: 24, channels: 2))
  ], "Unchanged polls report once, on main: \(reports.withLock { $0 })")
expect(reads.withLock { $0 } == 1, "Headers are cached between polls")
listing.withLock { $0 = [] }
pump(0.2)
expect(reports.withLock { $0 }.last?.format == nil, "A closed file clears the claim")
monitor.stop()
let countAfterStop = reports.withLock { $0.count }
listing.withLock { $0 = [("/m/a.flac", 99)] }
pump(0.2)
expect(reports.withLock { $0.count } == countAfterStop, "Stop ends reporting")
print("PASS: monitor main-queue reports, change-only delivery, header cache and stop")
print("Source-file checks passed (generated fixtures; no player or user file touched).")
