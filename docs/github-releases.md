# GitHub releases

Push a new `vX.Y.Z` tag to run `.github/workflows/release.yml`. The tag must match
the version in `Sources/anyrec/AnyRec.swift`. The workflow tests the tagged code,
builds universal Apple Silicon and Intel binaries, signs with Developer ID,
notarizes both products, verifies the extracted downloads, and publishes:

- `AnyRec-X.Y.Z.zip`: app with its notarization ticket stapled.
- `anyrec-X.Y.Z-universal.tar.gz`: CLI and its embedded Whisper framework.
- `SHA256SUMS`: checksums of both downloads.

The workflow uses GitHub's `macos-26` runner and its default Xcode. See the
[runner image inventory](https://github.com/actions/runner-images) for available tools.

## One-time setup

Add these repository secrets under **Settings → Secrets and variables → Actions**:

| Secret | Value |
|---|---|
| `ANYREC_CERTIFICATE_BASE64` | Base64 of a Developer ID Application certificate exported with its private key as a password-protected `.p12`. |
| `ANYREC_CERTIFICATE_PASSWORD` | Password protecting that `.p12`. |
| `ANYREC_NOTARY_KEY` | Contents of an App Store Connect **team API key** `.p8` authorized for notarization. |
| `ANYREC_NOTARY_KEY_ID` | That API key's ID. |
| `ANYREC_NOTARY_ISSUER_ID` | That API key's issuer ID. |

The signing identity defaults to `Developer ID Application: Doru Chiulan (D33CLM268G)`.
Set the repository variable `ANYREC_SIGN_IDENTITY` if the imported certificate has
a different identity. The workflow requires a valid Developer ID identity and
never falls back to ad-hoc signing.

Use GitHub's secret editor or `gh secret set` with file/stdin input. Do not paste
private keys or passwords into source, command arguments, or chat. The temporary
runner keychain and imported files are removed even after a failed release.
The workflow uses `GITHUB_TOKEN`; a separate GitHub PAT is not required.

Certificate import follows GitHub's
[macOS signing guidance](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
No provisioning profile is needed for this Developer ID distribution.

## Publish a version

1. Update `version:` in `Sources/anyrec/AnyRec.swift` and commit the intended app
   changes, workflow, scripts, and required resources. A tag contains committed
   files only; untracked local files cannot be built on GitHub.
2. Push that commit, then create and push its matching version tag:

   ```bash
   git tag -a v0.4.0 -m 'AnyRec 0.4.0'
   git push origin v0.4.0
   ```

3. Follow **Actions → Release**. Publication happens only after tests, signing,
   notarization, archive checks, and artifact upload succeed.
4. Update the Homebrew formula and cask version/checksums separately if distributing
   through the tap. The workflow does not edit those files.

Use a new version for each release; the commands above illustrate `v0.4.0`.
Only numeric stable tags are supported. Existing releases are never overwritten.

To retry a failed build for an existing tag, use **Actions → Release → Run workflow**
and enter the tag. Manual dispatch becomes available once the workflow is on the
default branch. If publication failed after creating a draft release, inspect its
assets and either finish that draft manually or remove the draft before retrying.
Published release tags must not be moved or reused.

## Local verification

```bash
swift test
bash -n scripts/ci-signing.sh scripts/release-tag.sh scripts/verify-release.sh
ANYREC_REQUIRE_NOTARIZATION=1 scripts/release.sh 0.4.0
ANYREC_REQUIRE_NOTARIZATION=1 bash scripts/verify-release.sh 0.4.0
```

Use the source version in the last two commands. Local notarization uses the
`anyrec-notary` keychain profile unless `ANYREC_NOTARY_PROFILE` overrides it.
Set `ANYREC_NOTARY_KEYCHAIN` if that profile is in a separate keychain.
Without strict mode, local builds may still produce ad-hoc or unnotarized artifacts;
the GitHub release workflow always enables strict mode.
