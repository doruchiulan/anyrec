# Website call scenes

[Proposals](Proposals.md) · [Page layout](../website/index.html) · [Capture guide](../website/CAPTURE.md)

## Before the call

The [recording reminder](../Sources/AnyRecBar/CallReminder.swift) floats in its own borderless panel above the [staged call window](../Sources/AnyRecBar/WebsiteDemo/DemoCall.swift).

![Recording reminder above the fictional Sketch review call](../website/assets/banner.png)

## During the call

The timer shares the Mac menu bar with Wi-Fi and the system clock. The [menu-bar panel](../Sources/AnyRecBar/StatusPanelPresentation.swift) opens directly beneath it with the [recording controls](../Sources/AnyRecBar/Views/RecordingPanel.swift).

![Elapsed time and two active meter levels](../website/assets/recording.png)

## After the call

The [sample transcript](../Sources/AnyRecBar/WebsiteDemo/DemoTranscript.swift) opens the same [speaker picker](../Sources/AnyRecBar/Views/SpeakersPanel.swift) as the recording library. [Watch the speaker correction](../website/assets/speaker-correction.webm).
