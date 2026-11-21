# AnyRec website

Static product page based on the supplied Claude Design “before, during, after”
layout. No dependencies, build step, analytics, or third-party fonts.

## Preview

From the repository root:

```sh
python3 -m http.server 8080 --directory website
```

Open http://localhost:8080. Screenshots link to their full-size originals.

## Publish

Upload this directory to a static host. Set `website` as the publish directory
and leave the build command empty. Relative asset links support subdirectories.

Set the purchase URL, button label, and price or compatibility note in
`site-config.js`. Update the fallback link and copy in `index.html` for visitors
without JavaScript. The current link goes to GitHub releases; the page does not
implement payment or licensing. No price has been assumed.

Support points to GitHub Issues. Set the public canonical URL once the domain is chosen. Replace the relative
`og:image` and `twitter:image` values with the absolute HTTPS URL of
`assets/social.png` before publishing. `README.md` and `FACTS.md` are maintenance documents;
they need not be uploaded.

## Screenshots and claims

The product screenshots in `assets/` are untouched native app captures.
The library screenshot uses staged sample audio, transcript, and summary
content; it demonstrates the interface, not transcription or summary accuracy.
No private conversation content is included. The reminder, recording panel and speaker correction movie use the separate [website demo build](CAPTURE.md). The icon comes from the Mac app.

[FACTS.md](FACTS.md) records the implementation evidence, known limits, and
screenshot provenance. Recheck it when changing product copy or app behavior.
Open [logo-options.html](logo-options.html) to compare the three SVG marks.
The selected Dual track mark shares its artwork with the favicon and social card.

## Checks

```sh
node --check website/app.js
node --check website/site-config.js
git diff --check -- website
```

Check section navigation, full-size screenshot links, the final download link,
keyboard focus, and narrow-screen layout after changing content.
