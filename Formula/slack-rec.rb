# Reference copy. The live formula is in github.com/doruchiulan/homebrew-tap;
# on each release, bump the url and paste the sha256 scripts/release.sh prints.
# Homebrew clears the quarantine flag on formula installs, so users never see
# the "unidentified developer" dialog.
class SlackRec < Formula
  desc "Record a Slack call: window video, system audio and microphone"
  homepage "https://github.com/doruchiulan/slack-recorder"
  url "https://github.com/doruchiulan/slack-recorder/releases/download/v0.1.0/slack-rec-0.1.0-universal.tar.gz"
  sha256 "531cc0c09c64b198c09ff37fd1b68531c567ecdf93a80e7059ed4d0ac6a096fa"
  license "MIT"

  # SCStreamConfiguration.captureMicrophone is a Sequoia API with no fallback.
  depends_on macos: :sequoia

  def install
    bin.install "slack-rec"
  end

  def caveats
    <<~EOS
      slack-rec needs two macOS permissions, granted to the terminal you run it
      from rather than to the binary:

        System Settings > Privacy & Security > Screen & System Audio Recording
        System Settings > Privacy & Security > Microphone

      Quit and reopen your terminal after granting them, then run:

        slack-rec doctor
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/slack-rec --version")
  end
end
