# AnyRec: Mac App Store and TestFlight release

Readiness assessed on 2026-10-23. This is a preparation guide, not a record of
submission. No App Store app record, price, agreement or tester group was changed.

## Distribution and pricing

The intended product is a paid Mac app. Price and currency are not selected yet.
TestFlight access is free during beta testing, independently of the store price.
Each build expires after 90 days; participation does not grant ownership of the
paid release. [Apple's TestFlight guide](https://testflight.apple.com/).

If testers should also receive the released app free, app promo codes grant a
copy that behaves as purchased. Apple currently allows up to 100 per version,
per platform; codes expire four weeks after generation. This is separate from
TestFlight access. [Promo codes](https://developer.apple.com/help/app-store-connect/offer-promo-codes/request-and-manage-promo-codes).

A paid download does not require an in-app purchase product or a TestFlight
payment bypass. An optional receipt/transaction ownership check is a separate
implementation decision. Do not add a subscription or server licensing system
unless the business model changes.

## Current build: not ready for store upload

The current app is a Developer ID distribution, built with SwiftPM and assembled
by `scripts/bundle-app.sh`. Its entitlement file contains microphone access only.
Apple requires App Sandbox for Mac App Store distribution and restricts downloaded
code and shared-location installation. [Review guideline 2.4.5](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility).

| Area | Current evidence | Required work or decision |
|---|---|---|
| Sandbox | `Resources/anyrec.entitlements` has no App Sandbox entitlement | Add and validate a dedicated store configuration; signing alone is insufficient. |
| Mute tracking and call banner | `MuteButton.Reader` reads another app's Accessibility tree; `CallWindowAnchor` depends on it | Replace with supported sandbox-compatible behavior, or omit these features from the store edition after deciding the product tradeoff. |
| ffmpeg | `FFmpegSetup.fetch` downloads and executes a standalone GPL build | Replace with native media processing, or assess a bundled, correctly licensed and signed helper. No runtime executable download. |
| LLM CLI providers | `LLMClient` invokes installed Claude, Codex and Gemini processes | Do not assume their executable, credentials and filesystem access work inside App Sandbox. A store edition can retain direct API providers; CLI parity needs a supported design. |
| Recording folders | Default is `~/Desktop/AnyRec Recordings`; preferences retain a path string | Use container storage or explicit folder selection with persistent security-scoped bookmarks. Validate reopen and migration. |
| Local models | Whisper is embedded; transcription and speaker models are downloaded | Keep executable code embedded. Verify model assets, compilation, caches, network access and first-use downloads in the sandbox. |
| Onboarding | `WelcomeAccess.allGranted` requires notifications and Accessibility | Notifications must be optional for core use; replace the Accessibility gate for a store edition. |
| Signing | Only Apple Development and Developer ID Application identities were found locally | Obtain appropriate Mac App Store signing, provisioning and installer credentials through the existing developer account. |
| Packaging/versioning | Current output is a notarized zip; build number equals marketing version | Add store archive/export validation and an independently increasing build number. Preserve direct distribution separately. |
| Privacy | Optional audio uploads, transcript review and saved voiceprints | Assess actual store-edition data flows and provider retention; prepare accurate privacy labels and policy. |

Apple lists cross-app assistive Accessibility usage among sandbox-incompatible
activities. The existing mute and call-window code depends on that access; do not
claim parity without a working supported alternative. [App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox).

Apple says push notifications cannot be required for core functionality. AnyRec's
notification reminders are also optional to recording, so remove the mandatory
notification gate before review. Recording itself needs explicit consent and a
visible or audible indicator. [Guidelines 4.5.4 and 2.5.14](https://developer.apple.com/app-store/review/guidelines/).

The downloaded ffmpeg build is identified as GPL in `FFmpegSetup.swift`. Bundling
it needs a licensing review as well as engineering work; native replacement avoids
assuming the current binary can simply move into the app bundle.

## Product decision before conversion

Recommended implementation sequence, if a store edition is desired:

1. Keep the existing direct-download app intact. Add a store configuration sharing
   recording, library, transcription and speaker logic.
2. Prove screen/window recording, microphone/system audio and local inference in
   an isolated sandboxed build. Use a separate development identity/container so
   the installed app's permissions and recordings are not disturbed.
3. Resolve mute tracking and call-banner behavior explicitly. If those features
   cannot be retained, describe the difference in onboarding and store metadata.
4. Replace executable downloads, adapt filesystem persistence, and use supported
   API integrations for optional cloud features.
5. Verify recordings, regeneration, model downloads, voice matching, app restarts
   and permission-denied paths before producing a store artifact.

Do not silently remove features to make an upload pass. If preserving all current
desktop integrations is the priority, direct paid distribution remains a separate
option; it does not provide TestFlight distribution for the current unsandboxed app.

## Apple account and listing

App Store Connect redirected to sign-in during this assessment. Current app
records, name availability, agreements, provisioning and banking remain unverified.
Do not create a duplicate or infer availability from the name in this repository.

1. Sign in to the intended developer team. Inspect existing records by bundle ID
   `com.doruchiulan.anyrec` before registering anything. Decide whether separate
   direct/store variants should share identity and data before changing identifiers.
2. Have the Account Holder complete the Paid Apps Agreement, tax and banking
   requirements. Do not copy Mainframe's free-app assumptions. [Agreements](https://developer.apple.com/help/app-store-connect/manage-agreements/sign-and-update-agreements/),
   [tax requirements](https://developer.apple.com/help/app-store-connect/manage-tax-information/provide-tax-information).
3. Confirm price, base currency, territories and the legal seller. Assess EU trader
   status from the actual business; free versus paid alone is not a complete rule.
   [Apple's trader guidance](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements).
4. Prepare Mac screenshots using harmless recordings, listing copy, support and
   privacy-policy URLs, age rating, category, copyright and review contact details.
5. Document optional provider uploads and local voice storage. Assess provider
   behavior rather than automatically declaring no data collection because the
   user supplies an API key. Review required-reason APIs, SDK manifests and licenses.
   [App privacy](https://developer.apple.com/app-store/app-privacy-details/).
6. Write review notes describing capture permissions, downloads, an entirely local
   usable path, optional external providers and the visible recording indicator.
   Reviewers should be able to test the app without the developer's personal keys.

## Build, beta and release

After compatibility work is complete:

1. Run the project's tests and release checks. Record source revision/worktree
   state, marketing version, build number, architecture, signing and entitlements.
2. Archive/export for App Store Connect with the correct Mac profiles and embedded
   executable/framework signatures. Validate the resulting store artifact. A
   successful Developer ID notarization is not store validation.
3. Upload using Xcode Organizer, Transporter or the current supported Apple CLI.
   Keep credentials in approved keychain/private-key storage, outside the repo.
4. Verify the exact build finishes processing. Configure internal or external beta
   groups deliberately; external testing requires the applicable Beta App Review.
   Do not assume later builds can never require another review.
5. Install through TestFlight on a real Mac, testing the sandboxed distribution
   rather than the existing `/Applications/AnyRec.app` Developer ID build.
6. Attach the tested build to the paid store version, complete metadata and submit
   for review with manual release selected if that is the chosen launch plan.
7. Verify approval separately from public availability. Release only the approved
   version under the user's launch instruction; record the final listing and build.

Keep these milestones distinct: built, locally tested, uploaded, processed,
available to testers, approved, publicly released. Report only verified milestones.

## Mainframe reference

The source process is in
`/Users/doruchiulan/Projects/qlan/mainframe/packages/mobile/README.md` and
`docs/app-store/{RELEASE_GUIDE,asc-forms,listing,review-notes,privacy-labels}.md`.
Its reusable sequence is preparation → distribution build → upload → TestFlight
verification → review → release. Its Expo `.ipa`, iOS push setup, demo pairing,
free price and app-specific form answers do not apply automatically to AnyRec.
