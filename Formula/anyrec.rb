# Reference copy of github.com/doruchiulan/homebrew-tap/Formula/anyrec.rb.
class Anyrec < Formula
  desc "Record calls with video, system audio, microphone and transcripts"
  homepage "https://github.com/doruchiulan/anyrec"
  url "https://github.com/doruchiulan/anyrec/releases/download/v0.5.0/anyrec-0.5.0-universal.tar.gz"
  sha256 "26f0186bd940a685e54be02e17e2d20110d2e2ceadc7eb841555eea92672650c"
  license "MIT"

  # SCStreamConfiguration.captureMicrophone is a Sequoia API with no fallback.
  depends_on macos: :sequoia

  # The signed binary resolves whisper.framework relative to its executable.
  def install
    bin.install "bin/anyrec"
    prefix.install "Frameworks"
  end

  def caveats
    <<~EOS
      anyrec needs two macOS permissions, granted to the terminal you run it
      from rather than to the binary:

        System Settings > Privacy & Security > Screen & System Audio Recording
        System Settings > Privacy & Security > Microphone

      Quit and reopen your terminal after granting them, then run:

        anyrec doctor

      Recordings land in ~/Desktop/AnyRec Recordings. ffmpeg is what merges the
      three tracks into a playable call.mp4; run anyrec with no arguments and
      ⏎ on Transcript fetches it along with Parakeet, the on-device engine, or:

        brew install ffmpeg
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/anyrec --version")
  end
end
