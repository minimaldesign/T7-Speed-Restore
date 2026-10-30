# T7 Speed Restore

A free Mac app that fixes the well-known slowdown on Samsung T7 SSDs, where write speeds degrade with use until file transfers crawl along at ~2 MB/s. One click brings the drive back to 500+ MB/s.

**Website and download:** [fixt7.com](https://fixt7.com)

Not affiliated with Samsung.

---

## How it works

The app creates a small, temporary partition on the drive. That single operation resets the T7’s internal state and restores full write speed. The partition is hidden from Finder automatically, and the app never opens or changes your files.

The fix is not permanent. The slowdown is a firmware-level issue with the T7 series, and the app doesn’t change the firmware. If the slowdown comes back, just run the app again.

---

## Requirements

- macOS 14 (Sonoma) or later
- A Samsung T7 SSD. Tested on the T7 Shield only. The plain T7 and the T7 Touch should work too if they have the same bug.
- The drive must be formatted as **APFS** (the default when you first set it up on a Mac). **exFAT and NTFS drives are not supported.**
- At least 26 GB of free space on the drive, used temporarily by the partition that triggers the speed reset
- The T7 can’t be the disk your Mac is starting up from

---

## Usage

1. Open the app
2. Drag your T7’s volume from Finder into the drop zone
3. Click **Run Benchmark** to confirm the slowdown
4. Click **Restore Speed** and enter your Mac password when prompted
5. Click **Run Benchmark** again to verify it worked

---

## What to expect during the fix

- **You’ll see a password prompt.** The fix needs to repartition your drive, which requires admin access. Because this app is self-distributed (not on the Mac App Store), the prompt appears every time you click **Restore Speed**. See “Why the password prompt?” below.
- **The first run can take a while.** Anywhere from a few minutes to over an hour, depending on the drive’s size, how much is on it, and how slow it has become. To make room for the partition, macOS first checks the drive’s file system, then moves any data stored in the last 25 GB of the drive elsewhere on the same drive, at the drive’s current, slowed-down speed. Later runs are much quicker because that space is already free.
- **The app shows its progress:** which step it’s on, the elapsed time, and how fast the drive is reading and writing. As long as the drive activity isn’t zero for a long stretch, it’s working. Don’t unplug the drive, quit the app, or close the lid until it says the fix was applied.
- **A volume called T7FIXER will briefly appear** on your desktop or in Finder. This is the small partition created by the fix. The app unmounts it automatically within a second or two. After that it stays hidden, including across reboots and replugs.

---

## First launch: macOS security warning

Because this app isn’t distributed through the Mac App Store, macOS will warn you the first time you open it.

To get past it:

1. Right-click (or Control-click) the app and choose **Open**
2. Click **Open** in the dialog that appears

Or go to **System Settings > Privacy & Security** and click **Open Anyway** after the first blocked launch attempt.

---

## Why the password prompt?

Apple requires a paid Developer Program membership ($99/year) to distribute apps that run privileged operations silently. This app skips that, so it asks for your password each time instead. Your password is used only to repartition the drive and is never stored or transmitted anywhere.

---

## Limitations

- exFAT-formatted T7 drives are not supported. If your drive shows up as exFAT in Disk Utility and you don’t need it on Windows, reformat it as APFS first (this erases the drive, so copy your data off beforehand).
- Windows-only T7 setups (formatted as NTFS or exFAT for Windows) are not supported. On Windows, open Device Manager, expand Disk drives, right-click your T7 and choose Properties. On the Policies tab, switch from Quick removal to Better performance and enable Write caching on the device.
- The drive must have no extra partitions after the main APFS volume. If you’ve added custom partitions yourself, remove them in Disk Utility before running the fix. Partitions in front of the main volume, such as the small “Microsoft Reserved” one left behind when a drive was set up on a Windows PC, don’t get in the way and can stay.

---

## Troubleshooting

- **“Storage system verify or repair failed” (error -69716):** macOS checked the drive’s file system before resizing it and found a problem. Open Disk Utility, select the T7 itself (the top-level entry, not just the volume), and run **First Aid**. Once it reports the drive is OK, run the fix again.
- **The fix seems stuck:** if the drive activity stays at zero for more than fifteen minutes, click **Copy Diagnostics** and get in touch.

To report a bug, [open an issue](https://github.com/minimaldesign/T7-Speed-Restore/issues) or use the email address in the [FAQ on fixt7.com](https://fixt7.com/#faq). Click **Copy Diagnostics** in the top-right corner of the app and paste the result into your message. It includes your macOS version, the drive’s partition layout, and the app’s log. If you can, also add your T7 model and capacity, and the benchmark numbers before and after running the fix.

---

## License

GPL-3.0
