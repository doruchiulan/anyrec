# Reference copy of github.com/doruchiulan/homebrew-tap/Formula/anyrec.rb.
class Anyrec < Formula
  desc "Record calls with video, system audio, microphone and transcripts"
  homepage "https://github.com/doruchiulan/anyrec"
  url "https://github.com/doruchiulan/anyrec/releases/download/v0.6.1/anyrec-0.6.1-universal.tar.gz"
  sha256 "70f53bd0ff7702fab6905b16398e7823e23e68836e417b6fcd194eb74100ebd2"
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
