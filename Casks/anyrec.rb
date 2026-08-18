# Reference copy. The live cask is in github.com/doruchiulan/homebrew-tap;
# on each release, bump the version and paste the zip's sha256 that
# scripts/release.sh prints.
#
# Casks quarantine what they install — that is what `--no-quarantine` exists to
# turn off — so the app this points at has to be notarised. Formulae are the ones
# that install unquarantined, which is why anyrec's CLI never needed it.
cask "anyrec" do
  version "0.2.0"
  sha256 "46fe5389858eda4f6716f54e9bab28fbbb35e0ac2ab742580fae3b2175225e57"

  url "https://github.com/doruchiulan/anyrec/releases/download/v#{version}/AnyRec-#{version}.zip"
  name "AnyRec"
  desc "Record any window or display: video, system audio and microphone as separate tracks"
  homepage "https://github.com/doruchiulan/anyrec"

  # SCContentFilter only reports what is in it from 15.2, which is how the picker
  # reads a selection back.
  depends_on macos: ">= :sequoia"

  app "AnyRec.app"

  caveats <<~EOS
    AnyRec lives in the menu bar — it has no Dock icon and no window.

    Open it once and it will ask for Screen Recording; grant that and Microphone
    under System Settings > Privacy & Security, then quit and reopen it. The
    grant only applies to newly launched processes.

    Recordings land in ~/Desktop/AnyRec Recordings. ffmpeg is what merges the
    three tracks into a playable call.mp4; without it you still get the tracks,
    but screen.mov has no audio of its own:

      brew install ffmpeg

    Setting whisper up, or pasting an OpenAI key, is a terminal job:

      brew install doruchiulan/tap/anyrec
  EOS

  zap trash: [
    "~/Library/Application Support/anyrec",
    "~/Library/Preferences/com.doruchiulan.anyrec.plist",
  ]
end
