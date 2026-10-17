# Tether

macOS 13+ menu bar app for unattended downloads from SSH hosts. Settings supports multiple hosts, multiple file/folder syncs, an interval of 1–1440 minutes, connection testing, and launch at login. New installs contain no hosts or jobs and have automatic sync disabled.

## Run and configure

Open Package.swift in Xcode or run `swift run`. Choose **Settings…** in the menu bar. Add a host, follow the SSH Setup tab, and test the connection. Add a sync with an absolute remote path and local target, save settings, and try Sync Now before enabling automatic sync. A file target is the complete filename. A folder target receives the contents of the remote folder. Removing a host leaves its jobs visible so they can be reassigned.

Tether uses the `nl.theredhead.tether` bundle identifier.

Configuration is saved as JSON at `~/Library/Application Support/Tether/configuration.json` with owner-only permissions. It contains hostnames and paths, never passwords or private key contents. Unsaved settings apply to the next manual sync but are lost at exit. An in-progress sync uses the configuration captured when it started.

Folder downloads are staged before merging. Local-only files are preserved; changed files are replaced atomically on the destination volume. An error during merging can leave earlier files updated, with the job reported as failed. Folder transfers are not a mirror and never delete local-only files. Avoid overlapping targets between jobs. Symbolic links encountered during local folder merging are rejected; SCP itself may follow remote symlinks, so use trusted remote sources. File transfers preserve the previous target if download fails. SCP supports paths with spaces via its default SFTP transport. Modern servers need SFTP enabled; legacy SCP protocol fallback is intentionally not enabled.

## Update notifications

Enable **Notify when files or folders are updated** in General Settings and allow Tether’s macOS notification prompt. Tether sends one notification per successfully updated sync entry, including manual syncs and initial downloads. Unchanged or failed syncs do not generate update notifications. Alerts also appear while Settings is active. Notifications show the sync name and local filename/folder name. Manage alert style, sound, and Focus behavior in System Settings → Notifications. Existing configurations keep notifications off until enabled.

## SSH authentication

The in-app SSH Setup tab includes commands to create a passphrase-protected Ed25519 key, install its public key on the remote account, use `ssh-add --apple-use-keychain`, configure `UseKeychain` and `AddKeysToAgent`, verify host fingerprints, and test BatchMode authentication. The Add Key button loads an existing key through macOS ssh-add; when a passphrase is needed, run the displayed command in Terminal. Private keys remain files on disk; Keychain stores passphrases. Existing SSH config aliases are supported. Connections require previously verified host keys and never prompt for a remote password. No SSH config or remote authorized_keys files are modified by the app.

The app must be running, with the user logged in, for scheduled transfers. Sleeping pauses sync. Launch at login uses SMAppService and requires the packaged app; macOS may require approval in System Settings → General → Login Items.

## Build a standalone app

Install Xcode command line tools, then run:

```sh
./scripts/build-app.sh
open dist/Tether.app
```

In a restricted development environment, set `DISABLE_SWIFTPM_SANDBOX=1` if SwiftPM cannot launch its nested build sandbox.

Copy the app to `/Applications` before enabling login startup. The script creates an Info.plist, menu bar agent bundle, and an ad hoc signed local app. Set `BUNDLE_ID`, `VERSION`, and `BUILD_NUMBER` for your release. When omitted, the build number increments from the previous bundle so macOS can recognize rebuilds. Use a stable bundle ID. `ARCH=arm64` or `ARCH=x86_64` builds for the specified architecture; build and distribute separate architecture releases. The app is intentionally unsandboxed because it invokes system SSH/SCP and accesses user-selected filesystem paths; this is for direct distribution, not the Mac App Store.

For distribution to other Macs, use a Developer ID Application certificate:

```sh
SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' ./scripts/build-app.sh
ditto -c -k --keepParent dist/Tether.app dist/Tether.zip
xcrun notarytool submit dist/Tether.zip --keychain-profile YOUR_NOTARY_PROFILE --wait
xcrun stapler staple dist/Tether.app
spctl --assess --type execute --verbose dist/Tether.app
ditto -c -k --keepParent dist/Tether.app dist/Tether-notarized.zip
```

Create YOUR_NOTARY_PROFILE using `xcrun notarytool store-credentials` with your developer account credentials. Do not commit signing credentials. Developer ID signing and notarization require your Apple Developer account and are not performed by the build script. The bundle includes a custom two-cans-and-string application icon. The menu bar uses a monochrome system symbol. `scripts/build-icon.sh` regenerates `Assets/Tether.icns` from `Assets/TetherIcon.png`; app packaging runs it automatically.
