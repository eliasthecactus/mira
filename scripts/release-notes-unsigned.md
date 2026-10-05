### Install

1. Download **Mira-*.dmg**, open it and drag **Mira** to **Applications**.
2. This build is not notarized by Apple, so macOS blocks the first launch. Open Mira once, then go to **System Settings -> Privacy & Security** and click **Open Anyway**.
   Or run this in Terminal instead: `xattr -dr com.apple.quarantine /Applications/Mira.app`
3. Mira lives in the menu bar. Allow **Local Network** access when asked. Screen Recording permission is requested when you first mirror.

Command line: `/Applications/Mira.app/Contents/MacOS/Mira help` (or `sudo ln -s /Applications/Mira.app/Contents/MacOS/Mira /usr/local/bin/mira`).
