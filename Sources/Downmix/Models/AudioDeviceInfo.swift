import CoreAudio
import Foundation

struct AudioDeviceInfo: Identifiable, Hashable, Sendable {
  let id: AudioDeviceID
  let name: String
  let uid: String
  let inputChannelCount: Int
  let outputChannelCount: Int
  let nominalSampleRate: Double

  var isInputCapable: Bool { inputChannelCount > 0 }
  var isOutputCapable: Bool { outputChannelCount > 0 }
  var isMultiChannelInput: Bool { inputChannelCount >= 16 }
  var isStereoOutput: Bool { outputChannelCount == 2 || outputChannelCount > 2 }

  var subtitle: String {
    var parts: [String] = []
    if inputChannelCount > 0 { parts.append("\(inputChannelCount) in") }
    if outputChannelCount > 0 { parts.append("\(outputChannelCount) out") }
    if nominalSampleRate > 0 {
      parts.append(String(format: "%.0f Hz", nominalSampleRate))
    }
    return parts.joined(separator: " · ")
  }
}
