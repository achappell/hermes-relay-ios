# TestFlight submission

The `TestFlight` GitHub Actions workflow archives the Release iOS target,
downloads the matching App Store provisioning profile, exports an App Store
IPA, and uploads it with the App Store Connect API. It supports a manual run
and is also called automatically by the release packaging workflow after a
tagged or Release Please release is packaged. It does not need a Hermes
endpoint, bearer token, or a connected device.

## One-time Apple setup

1. Create the `Hermes Relay` app record in App Store Connect with bundle ID
   `com.achappell.HermesRelay`.
2. Create an App Store Connect API key with at least the App Manager role.
   Record its issuer ID and key ID, and keep the downloaded `.p8` file private.
3. Create or download an Apple Distribution certificate and export its private
   key as a password-protected `.p12` file. The certificate must belong to the
   Apple Developer team configured by the Xcode project.
4. Leave the app target configured for Automatically manage signing. The
   Xcode-managed App Store profile named
   `iOS Team Store Provisioning Profile: com.achappell.HermesRelay` is expected.
   The workflow downloads the profile as a preflight check, then gives
   `xcodebuild` the App Store Connect authentication key and
   `-allowProvisioningUpdates` so Xcode can manage signing on the runner. The
   profile itself is not stored in the repository.

## GitHub configuration

Create a protected repository environment named `testflight`. Required
reviewers are recommended because a successful run uploads a real build to
App Store Connect.

Add these variables to the repository or the `testflight` environment:

| Name | Value |
| --- | --- |
| `APPSTORE_ISSUER_ID` | App Store Connect API key issuer ID |
| `APPSTORE_API_KEY_ID` | App Store Connect API key ID |

Add these secrets to the `testflight` environment so the signing material is
only available to an approved submission job. Repository-level secrets also
work if environment scoping is not available:

| Name | Value |
| --- | --- |
| `APPSTORE_API_PRIVATE_KEY` | Complete contents of the `AuthKey_*.p8` file |
| `APPSTORE_CERTIFICATES_FILE_BASE64` | Base64-encoded password-protected distribution `.p12` |
| `APPSTORE_CERTIFICATES_PASSWORD` | Password used when exporting the `.p12` |

On macOS, create the base64 value without printing the certificate contents:

```bash
base64 -i AppleDistribution.p12 | pbcopy
```

Paste the clipboard value into the `APPSTORE_CERTIFICATES_FILE_BASE64` secret.
Use GitHub's secret editor for the multiline `.p8` contents; never commit the
file or paste it into a workflow log.

## Running a submission

1. Open **Actions → TestFlight → Run workflow**. Select the branch to submit;
   `main` is the normal choice after the release PR is merged.
2. Enter a positive integer `build_number` higher than the latest build
   already in TestFlight. The normal release workflow supplies this value from
   its monotonically increasing GitHub Actions run number.
3. Optionally enter TestFlight release notes and leave **Wait for App Store
   processing** enabled when you want the workflow to report processing status.
4. Approve the `testflight` environment if its protection rules request it.

The workflow uses the Xcode project's current `MARKETING_VERSION`; a new
marketing version belongs in the normal Release Please flow. CI overrides
`CURRENT_PROJECT_VERSION` with its external integer `build_number` (normally
the GitHub Actions run number), and the app's `Stamp Build Number` build phase
does nothing when `CI=true`. The workflow retains the exported IPA and dSYM as
short-lived workflow artifacts for troubleshooting, but never uploads
certificates, provisioning profiles, API keys, or app credentials as artifacts.

## Local build numbers

Local builds stamp the built app's `CFBundleVersion` from a per-user counter in
`~/Library/Application Support/HermesRelay/ios-build-number`. The
`Stamp Build Number` phase runs after Info.plist processing and before code
signing, so every local build gets a new, higher number without editing
tracked files. The counter is local to one user on one Mac; it is not shared
between machines and is never used by CI.

The next number is the largest of the project's tracked
`CURRENT_PROJECT_VERSION` plus one, the previous counter plus one, and any
`CURRENT_PROJECT_VERSION` passed on the command line. A higher explicit value
such as `CURRENT_PROJECT_VERSION=99` is used exactly and the next default
build is 100; a lower value never moves the counter backward. Set
`HERMES_BUILD_NUMBER_DIR=<directory>` on the `xcodebuild` command line to use
a different counter directory.

## Automatic release submission

When `release.yml` packages a version from a release tag, it calls this same
workflow with the release tag as `release_ref`. The build number is the
release workflow's monotonically increasing GitHub run number, and the release
tag is used as the TestFlight release note. Keep manually entered build
numbers below future automatic run numbers, or choose a number higher than
both the latest uploaded build and the next release workflow run number.
