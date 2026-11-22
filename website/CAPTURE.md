# Website demo

Build and open the separate Mac app from the repository root.

```sh
scripts/bundle-website-demo.sh
open "dist/AnyRec Website Demo.app"
```

The demo works offline after the Swift build dependencies are available. Building it generates one spoken line with the macOS synthesizer. Opening it creates a fresh temporary recording and a voice library with fictional names. The demo uses its own bundle identifier and starts without requesting microphone, screen recording or Accessibility access.

| Scene | How to replay it |
| --- | --- |
| Before the call | Press ⌘1 to show the reminder above the fictional Sketch review call. Choose **Record** or **Audio Only**. |
| During the call | Press ⌘2 to restart the timer. The recording panel opens under the menu bar timer with two scripted meter levels. Press Escape to dismiss it and click the timer to reopen it. |
| After the call | Choose **Stop Recording** or press ⌘3. Click **Not sure who**, play the sample, then choose **Someone else…** and **Robin Vale**. The transcript updates immediately. Quit and reopen to reset the sample. |

For the reminder, capture the two windows named `AnyRec recording reminder` and `Sketch review` in one frame on a neutral background. For the recording panel, capture one region from the top of the display to just below the open panel. Include the real macOS menu bar with the timer, nearby system icons and clock. The website still uses a dark capture background for the white menu icons and a pale backdrop beneath the menu bar. Record just the demo app and its popover for the correction movie, then export it without an audio track. Check that every visible name and line belongs to the fixture before updating the assets.

The editable website scenes are in [WebsiteDemo](../Sources/AnyRecBar/WebsiteDemo/). The [page layout](index.html) and [screenshot styles](screenshots.css) place their captures under Before, During and After. See [FACTS.md](FACTS.md) for dimensions and provenance.
