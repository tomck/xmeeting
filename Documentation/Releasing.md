# Experimental macOS releases

`.github/workflows/macos-alpha.yml` builds a universal macOS 11+ app on an Intel
macOS 15 runner and runs all six tests. The same universal test binaries then
run natively on an Apple Silicon macOS 15 runner. No camera or microphone is
used in CI. A release is gated on both jobs; real-device and independent H.323
interoperability checks remain necessary.

Branch pushes produce the `macos-alpha-downloads` Actions artifact, retained for
14 days, without publishing a release. Check that **both** jobs passed before
sharing this artifact. Download it and unzip the outer Actions artifact to find
the app ZIP, matching source archive, and SHA-256 checksums.

## Publish a numbered alpha

After reviewing the commit and its successful Actions run, deliberately tag it:

```sh
# Example only: choose the next unused alpha number.
git tag -a v0.5.0-alpha.1 -m "XMeeting 0.5.0 alpha 1"
git push origin v0.5.0-alpha.1
```

Only tags of the form `vMAJOR.MINOR.PATCH-alpha.NUMBER` publish. The workflow
validates the name, reruns the checks, then creates a GitHub **prerelease**, never
the stable "latest" release. It refuses to overwrite an existing release.
No PAT or Apple credentials are needed: only the publish job gets the built-in
token's `contents: write` permission. Third-party action references are pinned
to verified commit IDs. Dependency tags are also checked against pinned commits;
the SDK cache key includes build scripts, patches, SDK version, and Xcode build.

This workflow lives on the modernization branch. Tag pushes work from that
branch; the optional Run workflow button requires the workflow on GitHub's
default branch. Do not change the default branch merely to enable that button.

## Distribution caveats

These are ad-hoc-signed alphas, not notarized releases. See
[the tester guide](AlphaTesting.md) for installation and network limitations.
Developer ID signing, hardened runtime, notarization, and macOS 11 real-device
verification are follow-up release work. Do not describe these builds as a
fully tested stable release or as Apple-verified.

A private repository means private releases, and Mac runners consume the
account's Actions allowance. Grant testers access or send them the complete
download and corresponding source; publishing this workflow does not change
repository visibility. Do not enable paid overage or public visibility implicitly.

## Local packaging

Use a clean, committed checkout and build dependencies first:

```sh
bash Scripts/build-h323plus-universal.sh
cmake -S Modern -B .build/release -DCMAKE_BUILD_TYPE=Release \
  -DXMEETING_APP_VERSION=0.5.0 -DXMEETING_APP_BUILD=1
cmake --build .build/release --parallel 3
ctest --test-dir .build/release --output-on-failure
bash Scripts/package-macos-alpha.sh .build/release .build/dist 0.5.0-alpha.1
```

The package script checks both architectures, bundle signature, minimum OS,
version, and system-only dynamic dependencies. It packages the app, notices,
version information, corresponding sources, and checksums without changing any
signing identities or overwriting an existing release asset. Numeric bundle
versions are separate from the human-readable alpha tag in `Build.txt`.

Upstream source archives in the source download are unmodified snapshots. The
three files in `Dependencies/patches/` and
`Scripts/build-h323plus-universal.sh` specify our changes and build procedure.
The script normally fetches those pinned revisions from GitHub; the supplied
archives also preserve the source if upstream hosting changes.
