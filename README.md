# Reveal in Drive

A tiny macOS menu bar app: paste a Google Drive link, and it reveals the file in Finder, like "Reveal in Finder" for Drive links.

## Use

- **Menu bar icon:** opens a field that's pre-filled with any Drive link on your clipboard. Press Return to reveal.
- **⌃⌥⌘D** (works in any app): reveals the Drive link on your clipboard right away.
- **Open at login:** a checkbox in the menu.
- **CLI:** `"/Applications/Reveal in Drive.app/Contents/MacOS/Reveal in Drive" <link> [--reveal]` prints the local path.

Supported links: `drive.google.com/file/d/…`, `/drive/folders/…`, `docs.google.com/{document,spreadsheets,presentation,forms}/d/…`, `open?id=…`, or a bare ID.

## How it works

Google Drive for Desktop keeps a local metadata database per account at
`~/Library/Application Support/Google/DriveFS/<account-id>/metadata_sqlite_db`.
The app looks up the ID from the link, walks parent folders (and Drive shortcuts) up to `My Drive` or a shared drive root, then builds the path under the matching `~/Library/CloudStorage/GoogleDrive-<email>/` mount. It matches each mount to its account through the mount's `com.apple.file-provider-domain-id` xattr. It needs no network access or Google sign-in.

### Limitations

- Only items Drive for Desktop actually shows in Finder can be revealed. A file "shared with me" without a shortcut in your Drive isn't on disk.
- It relies on Drive for Desktop's internal database layout, which Google could change.

## Build

Requires Xcode command line tools, and builds for macOS 14+.

```bash
./build.sh            # builds build/Reveal in Drive.app
./build.sh --install  # also copies to /Applications and launches it
```
