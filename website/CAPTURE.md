# Capture the call scenes

Use a private Slack test workspace or a Teams test tenant with a second test
account on another device. Give both accounts fictional display names. Close
private windows and notifications before capturing. Use an untitled solid-color
desktop or the site's existing background treatment for the surrounding page.
Keep the screenshots as single native captures.

1. Launch an isolated AnyRec bundle under a scratch home, as described below.
   In System Settings → Privacy & Security, grant that bundle Screen Recording,
   Microphone, and Accessibility. Relaunch the same signed bundle after granting
   Screen Recording. In AnyRec General settings, enable call reminders and the
   menu bar item. Leave automatic recording disabled.
2. Open a Slack huddle or Teams call in its own window. Have the second test
   account join and speak a scripted line. When AnyRec offers to record, capture
   a single region containing the whole banner and call window with
   `screencapture -i -x banner.png`.
3. Choose Record. With both sides speaking scripted lines, open AnyRec's menu
   bar panel and capture one region containing the menu bar timer and the entire
   panel with `screencapture -i -x recording.png`. Enable Do Not Disturb before
   this step so personal alerts stay out of the capture.
4. Stop the recording and quit the test bundle. Review the full files for private
   content before putting them in `assets/`. Record the source build, test
   content and capture method in `FACTS.md`. Remove the test bundle's grants
   and delete its scratch recordings, preferences and saved state when done.

## Isolated bundle

Copy the source tree into a fresh folder under `/private/tmp` and run
`ANYREC_SIGN_IDENTITY=- bash scripts/bundle-app.sh` there. Copy the new app to a
separate staging location, change its `CFBundleIdentifier` to a unique test ID
and ad-hoc sign the copy with `codesign --force --deep -s - <test-app>`.
Use `defaults write <test-id> welcomed -bool YES` and set
`recordCallsAutomatically`, `compressesRecordings` and
`SUEnableAutomaticChecks` to false in the test domain. Set `recordingsFolder`
to an absolute path under the scratch home. Launch the test app binary with
`CFFIXED_USER_HOME` pointing at the scratch home. Verify its library shows only
test content before starting the call.
