# Reference copy of github.com/doruchiulan/homebrew-tap/Casks/anyrec-app.rb.
cask "anyrec-app" do
  version "0.10.0"
  sha256 "b84b829aa4f424dc62385fef8b243e0bcef0c7d29d4c6f8a5d4b01c4cecb2e16"

  url "https://github.com/doruchiulan/anyrec/releases/download/v#{version}/AnyRec-#{version}.zip"
  name "AnyRec"
  desc "Record calls with video, system audio, microphone and transcripts"
  homepage "https://github.com/doruchiulan/anyrec"

  # Reading the capture picker selection requires macOS 15.2.
  depends_on macos: :sequoia

  app "AnyRec.app"

  zap trash: [
    "~/Library/Application Support/anyrec",
    "~/Library/Preferences/com.doruchiulan.anyrec.plist",
  ]

  caveats <<~EOS
    AnyRec is a Mac app with a small helper in the menu bar.

    Open it once and it will ask for Screen Recording; grant that and Microphone
    under System Settings > Privacy & Security, then quit and reopen it. The
    grant only applies to newly launched processes.

    Recordings land in ~/Library/Application Support/anyrec/Recordings. The first launch walks through
    permissions and setup: transcription on this Mac is a download (Parakeet,
    25 languages, or Whisper, 99). AnyRec also downloads ffmpeg when needed to
    merge the tracks into call.mp4. The terminal tool is a separate install:

      brew install doruchiulan/tap/anyrec
  EOS
end
