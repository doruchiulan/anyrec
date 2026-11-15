import CryptoKit
import Foundation
import Testing

@testable import AnyRecKit

/// A manual look at the Speakers panel's candidates on copies of real recordings, run only
/// when `ANYREC_SPEAKERS_CHECK_DIR` names a folder of copied recording folders. It only
/// reads. Names are printed as short hashes, so the output can be shared; point
/// `ANYREC_VOICE_LIBRARY` at a copy of the library for the library-dependent parts.
@Suite("Real recording speakers check")
struct RealRecordingSpeakersCheck {
    static let folder = ProcessInfo.processInfo.environment["ANYREC_SPEAKERS_CHECK_DIR"]

    @Test("prints every voice's candidates, hashed", .enabled(if: folder != nil))
    func check() throws {
        let root = URL(fileURLWithPath: try #require(Self.folder))
        let library = VoiceLibrary.load()
        let hash = { (name: String) -> String in
            SHA256.hash(data: Data(VoiceLibrary.normalized(name).utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        }
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("rec-") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for folder in folders {
            guard let speakers = RecordingSpeakers.read(in: folder, library: library) else {
                print("speakers-check: \(folder.lastPathComponent) no transcript")
                continue
            }
            let roster = speakers.participants?.roster.map { hash($0.name) } ?? []
            print("speakers-check: \(folder.lastPathComponent) app=\(RecordingInfo.read(folder)?.appName ?? "-") to-check=\(speakers.needsChecking) roster=\(roster) unclaimed=\(speakers.unclaimedLines) lines/\(Int(speakers.unclaimedTime)) s")
            for row in speakers.rows {
                let who: String = switch row.speaker {
                case .me: "Me"
                case .others: "Call"
                case .voice(let letter): "Speaker \(letter)"
                case .named: "named line"
                }
                let clips = row.clips.map { "\(Int($0.start))-\(Int($0.end))" }.joined(separator: ",")
                print("speakers-check:   \(who) name=\(row.name.map(hash) ?? "-") basis=\(row.basis.rawValue) talk=\(Int(row.talkTime)) s lines=\(row.lineCount) clips=[\(clips)] corrections=\(row.corrections.count) fused=\(row.fusedNames.map(hash)) attention=\(row.needsAttention) yourVoice=\(row.yourVoice.map(\.rawValue)) remember=\(row.rememberOwner.map { "\(hash($0.person)) alias=\($0.display.map(hash) ?? "-")" } ?? "-")")
                for candidate in row.candidates {
                    let reason: String = switch candidate.reason {
                    case .introduced(let quote): "introduced(quote \(hash(quote)))"
                    case .yourVoice(let evidence): "yourVoice(\(evidence.map(\.rawValue)))"
                    default: "\(candidate.reason)"
                    }
                    print("speakers-check:     \(candidate.isMe ? "Me" : hash(candidate.name)) \(reason)")
                }
            }
            for candidate in speakers.callCandidates {
                print("speakers-check:   Call line candidate \(hash(candidate.name)) \(candidate.reason)")
            }
        }
    }
}
