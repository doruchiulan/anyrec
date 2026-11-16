# Reference copy of github.com/doruchiulan/homebrew-tap/Casks/anyrec-app.rb.
cask "anyrec-app" do
  version "0.7.1"
  sha256 "a57b036c6872323e03c826ec194f924dd101a5a910f77a4f2cb107940c522174"

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

    Recordings land in ~/Desktop/AnyRec Recordings. The first launch walks through
    permissions and setup: transcription on this Mac is a download (Parakeet,
    25 languages, or Whisper, 99). AnyRec also downloads ffmpeg when needed to
    merge the tracks into call.mp4. The terminal tool is a separate install:

      brew install doruchiulan/tap/anyrec
  EOS
end
