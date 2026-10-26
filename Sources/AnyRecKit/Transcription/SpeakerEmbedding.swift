import CoreML
import FluidAudio
import Foundation

struct SpeakerEmbedding {
    let models: OfflineDiarizerModels

    enum Failure: Error {
        case incompatibleModel
        case insufficientAudio
        case invalidEmbedding
    }

    func extract(_ samples: [Float]) throws -> Voiceprint {
        guard samples.count >= 32_000, samples.allSatisfy(\.isFinite),
              samples.contains(where: { abs($0) > 0.001 }) else { throw Failure.insufficientAudio }
        let audio = try input("audio", of: models.fbankModel)
        guard audio.count == 160_000 else { throw Failure.incompatibleModel }
        let count = min(samples.count, audio.count)
        // Repeat short speech spans to fill the pinned model's ten-second window without adding silence.
        for index in 0..<audio.count { audio[index] = NSNumber(value: samples[index % count]) }
        let features = try predict(models.fbankModel, inputs: ["audio": audio], output: "fbank_features")
        let weights = try input("weights", of: models.embeddingModel)
        for index in 0..<weights.count { weights[index] = 1 }
        let output = try predict(models.embeddingModel,
            inputs: ["fbank_features": features, "weights": weights], output: "embedding")
        let result = (0..<output.count).map { output[$0].floatValue }
        guard result.count == 256, result.allSatisfy(\.isFinite), result.contains(where: { $0 != 0 }) else {
            throw Failure.invalidEmbedding
        }
        return result
    }

    private func input(_ name: String, of model: MLModel) throws -> MLMultiArray {
        guard let shape = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint?.shape,
              !shape.isEmpty, shape.allSatisfy({ $0.intValue > 0 }) else { throw Failure.incompatibleModel }
        return try MLMultiArray(shape: shape, dataType: .float32)
    }

    private func predict(_ model: MLModel, inputs: [String: MLMultiArray], output: String) throws -> MLMultiArray {
        let provider = try MLDictionaryFeatureProvider(dictionary: inputs.mapValues { MLFeatureValue(multiArray: $0) })
        let result = try model.prediction(from: provider)
        guard let array = result.featureValue(for: output)?.multiArrayValue else { throw Failure.incompatibleModel }
        return array
    }
}
