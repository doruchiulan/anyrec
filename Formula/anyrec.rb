# Reference copy of github.com/doruchiulan/homebrew-tap/Formula/anyrec.rb.
class Anyrec < Formula
  desc "Record calls with video, system audio, microphone and transcripts"
  homepage "https://github.com/doruchiulan/anyrec"
  url "https://github.com/doruchiulan/anyrec/releases/download/v0.8.1/anyrec-0.8.1-universal.tar.gz"
  sha256 "2cd0a2d446222b0a7c75d81e493bf1139c7f9251d7d85cc3d88e72aed8d0d45f"
  license "MIT"

  # SCStreamConfiguration.captureMicrophone is a Sequoia API with no fallback.
  depends_on macos: :sequoia

  # The signed binary resolves whisper.framework relative to its executable.
  def install
    bin.install "bin/anyrec"
    prefix.install "Frameworks"
  end

  # Homebrew rewrites the framework's install name to a path in the keg and signs it ad
  # hoc, and a hardened-runtime binary carrying a Team ID refuses to load a library
  # without that Team ID, so the binary would not start. Both are signed ad hoc, without
  # the hardened runtime, after that rewrite, so they load together. Formulae are not
  # quarantined, so notarization does not apply here; the cask's app keeps it.
  def post_install
    system "/usr/bin/codesign", "--force", "--sign", "-", prefix/"Frameworks/whisper.framework"
    system "/usr/bin/codesign", "--force", "--sign", "-", bin/"anyrec"
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
