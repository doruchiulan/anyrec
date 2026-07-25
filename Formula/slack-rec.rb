# Copy this into your tap repo (github.com/doruchiulan/homebrew-tap) as
# Formula/slack-rec.rb, filling in the version and sha256 that
# scripts/release.sh prints. Homebrew clears the quarantine flag on formula
# installs, so users never see the "unidentified developer" dialog.
class SlackRec < Formula
  desc "Record a Slack call: window video, system audio and microphone"
  homepage "https://github.com/doruchiulan/slack-recorder"
  url "https://github.com/doruchiulan/slack-recorder/releases/download/v0.1.0/slack-rec-0.1.0-universal.tar.gz"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_SCRIPT"
  version "0.1.0"
  license "MIT"

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
    assert_match "slack-rec", shell_output("#{bin}/slack-rec --version 2>&1", 0)
  end
end
