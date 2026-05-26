# Samsung T7 Speed Restore

Fixes the well-known write speed bug on Samsung T7, T7 Shield, and T7 Touch SSDs where the drive slows down to ~2 MB/s after a while. One click brings it back to 500+ MB/s.

---

## How it works

The fix is to create a small temporary partition on the drive. This resets the drive's internal state and restores full write speed. The partition is hidden from Finder automatically. Your data is not touched.

The fix is not permanent. If the slowdown comes back, just run the app again.

---

## Requirements

- macOS 15 (Sequoia) or later
- A Samsung T7, T7 Shield, or T7 Touch
- The drive must be formatted as **APFS** (the default when you first set it up on a Mac). **exFAT-formatted drives are not supported.**
- At least 6 GB of free space on the drive

---

## Usage

1. Open the app
2. Drag your T7's volume from Finder into the drop zone
3. Click **Run Benchmark** to confirm the slowdown
4. Click **Restore Speed** and enter your Mac password when prompted
5. Click **Run Benchmark** again to verify it worked

---

## What to expect during the fix

- **You'll see a password prompt.** The fix needs to repartition your drive, which requires admin access. Because this app is self-distributed (not on the Mac App Store), the prompt appears every time you click Fix. See "Why the password prompt" below.
- **A volume called T7FIXER will briefly appear** on your desktop or in Finder. This is the small partition created by the fix. The app unmounts it automatically within a second or two. After that it stays hidden, including across reboots and replugs.

---

## First launch: macOS security warning

Because this app isn't distributed through the Mac App Store, macOS will warn you the first time you open it.

To get past it:

1. Right-click (or Control-click) the app and choose **Open**
2. Click **Open** in the dialog that appears

Or go to **System Settings > Privacy & Security** and click **Open Anyway** after the first blocked launch attempt.

---

## Why the password prompt?

Apple requires a paid Developer Program membership ($99/year) to distribute apps that run privileged operations silently. This app skips that, so it asks for your password each time instead. Your password is used only to repartition the drive and is never stored or transmitted anywhere.

---

## Limitations

- exFAT-formatted T7 drives are not supported. If your drive shows up as exFAT in Disk Utility, reformat it as APFS first (this will erase it).
- The drive must have no extra partitions after the main APFS volume. If you've added custom partitions manually, remove them before running the fix.
- Windows-only T7 setups (formatted as NTFS or exFAT for Windows) are not supported.

---

## License

GPL-3.0
