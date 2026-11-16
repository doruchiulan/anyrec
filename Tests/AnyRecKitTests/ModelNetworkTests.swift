import FluidAudio
import Foundation
import Testing

@testable import AnyRecKit

@Suite("FluidAudio's network switch")
struct ModelNetworkTests {
    @Test("a download finishing does not turn the network off under one still running")
    func overlapping() async throws {
        let (entered, enter) = AsyncStream.makeStream(of: Void.self)
        let (released, release) = AsyncStream.makeStream(of: Void.self)
        let parakeet = Task {
            try await ModelNetwork.downloading {
                enter.yield()
                for await _ in released { break }
            }
        }
        for await _ in entered { break }

        try await ModelNetwork.downloading {}
        #expect(!ModelHub.offlineMode, "the speaker models finishing used to cut Parakeet off here")
        ModelNetwork.offline()
        #expect(!ModelHub.offlineMode, "a transcription starting does not cut it off either")

        release.yield()
        try await parakeet.value
        #expect(ModelHub.offlineMode)
    }
}
