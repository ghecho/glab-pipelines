# Releasing Pipelines

This page tells you how to publish a signed release that teammates install once and that then updates itself. You do the setup once, on the Mac that holds your Apple developer certificate. After that, each release is one command.

A release is a GitHub release in a public repository. It holds the zipped app and `appcast.xml`, the file that Sparkle reads to find new versions. Sparkle is the update framework in the app. It checks for a new version once a day and asks before it installs one.

## What you need

- A paid Apple Developer Program membership. A free Apple ID cannot make a Developer ID certificate.
- The Xcode command line tools, as for a normal build.
- The GitHub command line tool, `gh`, logged in to the account that owns the releases repository.
- A clone of this repository on that Mac.

## One-time setup

### 1. Install a Developer ID certificate

1. Open Keychain Access. In the menu, choose Keychain Access, then Certificate Assistant, then Request a Certificate From a Certificate Authority.
2. Enter your email and name, select "Saved to disk", and save the request file.
3. On developer.apple.com, open Certificates, IDs & Profiles, then Certificates, and click +.
4. Select "Developer ID Application", upload the request file, and download the certificate.
5. Double-click the downloaded certificate to add it to your keychain.
6. Make sure that the certificate is installed. This command lists it as `Developer ID Application: <your name> (<team ID>)`:

```bash
security find-identity -v -p codesigning
```

Copy that full name. It is your `SIGN_IDENTITY`.

### 2. Store your notarization credentials

Apple must notarize the app, which means scan it, before macOS opens it with no warning. `notarytool` needs an app-specific password.

1. On account.apple.com, open Sign-In and Security, then App-Specific Passwords, and make a password called "notarytool".
2. Store it in your keychain under the name `pipelines-notary`. The command asks for the password.

```bash
xcrun notarytool store-credentials pipelines-notary --apple-id <your Apple ID email> --team-id <team ID>
```

`pipelines-notary` is your `NOTARY_PROFILE`.

### 3. Make the Sparkle signing keys

Sparkle accepts an update only if it carries a signature from your private EdDSA key. The app holds the matching public key.

1. Download Sparkle's tools. Use the version that `Package.resolved` names, 2.10.0 at the time of writing. `release.sh` uses the same folder later.

```bash
mkdir -p build/sparkle-2.10.0
curl -fsSL https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz | tar -xJ -C build/sparkle-2.10.0
```

2. Make the keys. The tool stores the private key in your keychain and prints the public key.

```bash
build/sparkle-2.10.0/bin/generate_keys
```

   Copy the public key. It is your `SPARKLE_PUBLIC_KEY`.

3. Export the private key and keep the file in your password manager.

```bash
build/sparkle-2.10.0/bin/generate_keys -x sparkle-private-key.txt
```

   Then delete `sparkle-private-key.txt` from the disk.

Do not lose the private key. Without it, you cannot sign updates, and every teammate must install the next version by hand. To use the key on a new Mac, import it with `generate_keys -f sparkle-private-key.txt`.

### 4. Make the releases repository

Make a public GitHub repository that holds only releases, for example `pipelines-releases`. The source repository can stay private.

Log in with `gh` if you have not already:

```bash
gh auth login
```

The repository's `<owner>/<name>`, for example `your-name/pipelines-releases`, is your `GITHUB_REPO`.

### 5. Save the variables

Write the four values to a file outside the repository, for example `~/.pipelines-release.env`:

```bash
export SIGN_IDENTITY="Developer ID Application: <your name> (<team ID>)"
export NOTARY_PROFILE="pipelines-notary"
export SPARKLE_PUBLIC_KEY="<public key from generate_keys>"
export GITHUB_REPO="<owner>/pipelines-releases"
```

The file holds no secrets: the certificate, the notarization password and the private key stay in your keychain. Do not commit it, because the identity and the repository name belong to you.

## Publish a release

1. Raise the number in `VERSION`, for example from `0.2.0` to `0.2.1`, and commit the change.
2. Load the variables and run the release script:

```bash
. ~/.pipelines-release.env
scripts/release.sh
```

The script does these steps:

1. It stops if a variable is missing, or if a release with this version already exists.
2. It builds the app with your Developer ID signature, the hardened runtime, the feed URL and the public key. It does not install the app.
3. It sends a zip to Apple and waits for notarization. This usually takes a few minutes.
4. It staples the notarization ticket to the app and zips the app again.
5. It signs the zip with your private key and writes `appcast.xml`.
6. It creates the GitHub release `v<version>` with the zip and `appcast.xml`.

The app reads its feed from `https://github.com/<owner>/<name>/releases/latest/download/appcast.xml`. GitHub sends that address to the `appcast.xml` of the newest release, so the address never changes. Do not mark a release as a draft or a prerelease, because GitHub then does not count it as the latest.

## The first release

Before you send the first release to anyone, do these checks:

1. Make sure that macOS accepts the app. The command prints `accepted` and `source=Notarized Developer ID`:

```bash
spctl -a -vv build/Pipelines.app
```

2. Download the zip from the release page, unzip it, move Pipelines to Applications, and open it. It must open with no warning.
3. Click the gear icon. The menu must show "Check for Updates…".
4. Publish a second release, for example `0.2.1`. In the installed `0.2.0`, click the gear icon, then Check for Updates…. Sparkle must offer `0.2.1`, install it, and start it again.

## Your own Mac

`scripts/bundle.sh` installs a dev build with no feed URL, so that copy never updates itself. To get updates on your own Mac, install the released zip instead. If you run `scripts/bundle.sh` later, it replaces the released copy with a dev build again.

## Troubleshooting

If notarization fails, the script stops before it publishes anything. To see why Apple rejected the app, read the log. `notarytool` prints the submission id.

```bash
xcrun notarytool log <submission id> --keychain-profile pipelines-notary
```

If the script says that the release already exists, raise the number in `VERSION`.

If Sparkle says that an update is not signed correctly, the `SPARKLE_PUBLIC_KEY` in the installed app does not match the private key in your keychain. Make sure that you use the key pair from step 3.
