# Third-party notices

## Speaker models

Telling the far end's voices apart uses [FluidAudio](https://github.com/FluidInference/FluidAudio)
(Apache-2.0) and its Core ML conversion of
[pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1),
fetched from `FluidInference/speaker-diarization-coreml` on first use. The offline
model files — `Segmentation`, `FBank`, `Embedding`, `PldaRho`, `plda-parameters.json`,
`xvector-transform.json` — are licensed under
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) and are modified Core ML
conversions of work by pyannote, WeSpeaker, BUT Speech@FIT and Fluid Inference.

They run on your machine. Nothing they compute is sent anywhere.

## Parakeet TDT 0.6B v3

Speech recognition on this Mac runs NVIDIA's Parakeet TDT 0.6B v3, in the CoreML
conversion published by FluidInference (`FluidInference/parakeet-tdt-0.6b-v3-coreml`)
and run by FluidAudio. The model is released by NVIDIA under the Creative Commons
Attribution 4.0 licence. It is downloaded on request, never shipped with the app.

## ffmpeg

When no ffmpeg is on the machine, AnyRec downloads a static build of ffmpeg 6.0 from
the ffmpeg-static project's releases (https://github.com/eugeneware/ffmpeg-static),
which redistributes the macOS builds from osxexperts.net. That build is under the GNU
General Public License, version 2 or later, with components under version 3; AnyRec
runs it as a separate program and does not link against it. Its source is available
from https://ffmpeg.org.

## whisper.cpp

whisper transcription runs whisper.cpp (https://github.com/ggml-org/whisper.cpp) and
ggml, by Georgi Gerganov and contributors, linked into the app as the framework its
own builds produce. Both are under the MIT License:

    Permission is hereby granted, free of charge, to any person obtaining a copy of
    this software and associated documentation files (the "Software"), to deal in the
    Software without restriction, including without limitation the rights to use, copy,
    modify, merge, publish, distribute, sublicense, and/or sell copies of the Software,
    subject to the above copyright notice and this permission notice being included in
    all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS
    IS", WITHOUT WARRANTY OF ANY KIND.

The models (ggml-large-v3-turbo, Silero VAD) are downloaded on request, never shipped.
