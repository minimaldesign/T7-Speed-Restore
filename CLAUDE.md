# Samsung T7 Fixer

A macOS app that restores Samsung T7 / T7 Shield / T7 Touch external SSDs to
their normal write speed when they hit the well-documented "drops to ~2 MB/s
after a while" bug. The fix is to create a fresh exFAT partition on the
drive — the act of doing so resets some controller state and the drive's
write speed returns to ~500 MB/s. The fix is not permanent; the user is
expected to re-run T7Fixer periodically.

## What the app does, end to end

1. User drags their T7's mounted volume (e.g. `/Volumes/MyT7Data`) onto the
   drop zone in the app window.
2. App validates the drop: external/removable drive, Samsung T7 family,
   APFS- or HFS+-formatted, has ≥26 GB free, has no extra GPT partitions
   sitting after the APFS container.
3. User clicks **Restore Speed**.
4. App runs (as root, via an admin-authentication prompt) a bash script that:
   - removes any pre-existing `T7FIXER` GPT partition and grows APFS back,
   - shrinks the APFS container by 25 GiB,
   - creates a fresh 25 GB exFAT partition named `T7FIXER` in the freed space,
   - tries (best-effort) to write a `noauto,ro` entry to `/etc/fstab`,
   - unmounts the new partition.
5. App installs a per-user **LaunchAgent** at
   `~/Library/LaunchAgents/net.mnmldsgn.t7fixer.unmount-watcher.plist`
   that watches `/Volumes/T7FIXER` and auto-unmounts it whenever macOS
   mounts it (initial creation, replug, reboot-with-drive-attached). This
   is the actual mechanism that keeps `T7FIXER` invisible to the user, since
   `/etc/fstab` is not writable via osascript-elevated bash on
   Sequoia+ (see "Gotchas" below).
6. Separate **Benchmark** card lets the user run a 6-second F_NOCACHE
   write test on the T7's main volume to verify the fix worked.

## Distribution

- **Self-hosted download from yann's website. NOT Mac App Store.**
- Bundle ID: `net.mnmldsgn.t7fixer` (mnmldsgn brand, not `com.yann.*`).
- Ad-hoc signed (`CODE_SIGN_IDENTITY="-"`). No paid Apple Developer Program
  enrollment.
- Users will see Gatekeeper's "not from an identified developer" warning on
  first launch and need to right-click → Open or use System Settings →
  Privacy & Security → "Open Anyway". The README/landing page should walk
  them through it.

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  SwiftUI app (drag-and-drop, Fix button, Benchmark button)     │
│  ContentView.swift                                             │
└────────────┬───────────────────────────────────────┬───────────┘
             │                                       │
             ▼                                       ▼
   ┌─────────────────┐                  ┌──────────────────────┐
   │ T7Detector      │                  │ FixCoordinator       │
   │ (read-only      │                  │ (@MainActor state    │
   │  diskutil)      │                  │  machine)            │
   └─────────────────┘                  └──────────┬───────────┘
                                                    │
                                                    ▼
                                  ┌──────────────────────────────┐
                                  │ PrivilegeRouter              │
                                  │ Inspects own code signature  │
                                  │ via SecCodeCopySelf.         │
                                  └─┬──────────────────────────┬─┘
                       Team ID found │                          │ no Team ID
                                     ▼                          ▼
                          ┌──────────────────┐      ┌─────────────────────┐
                          │ SMAppServiceBr.  │      │ OsascriptBridge     │
                          │ (signed builds:  │      │ (the current path:  │
                          │  XPC to a root   │      │  builds a bash      │
                          │  daemon helper)  │      │  script, runs it    │
                          │                  │      │  via NSAppleScript  │
                          │                  │      │  do shell script    │
                          │                  │      │  with admin privs)  │
                          └────────┬─────────┘      └──────────┬──────────┘
                                   │                           │
                                   └──────────────┬────────────┘
                                                  ▼
                                    same diskutil sequence
                                    (shrink APFS, add exFAT)

After the fix script returns:
   ┌─────────────────────────────────────────────────────────┐
   │ MountWatcher                                            │
   │ Installs ~/Library/LaunchAgents/...unmount-watcher.plist│
   │ which watches /Volumes/T7FIXER and unmounts on sight.   │
   └─────────────────────────────────────────────────────────┘
```

## Two privilege paths

The app supports two paths for the privileged disk operations. The runtime
choice happens in `PrivilegeRouter.detectPath()`, which reads the app's own
code signature via `SecCodeCopySelf` + `SecCodeCopySigningInformation` and
looks for `kSecCodeInfoTeamIdentifier`:

1. **`.osascript`** (current — no Developer ID required). Builds a bash
   script as a Swift string, writes it to a temp file in
   `NSTemporaryDirectory()`, runs it via
   `NSAppleScript("do shell script ... with administrator privileges")`.
   The user sees a password prompt each time the Fix button is clicked.
   This is `OsascriptBridge.swift`.

2. **`.smAppService`** (latent — kicks in if/when Yann gets a Developer ID).
   Uses the bundled launchd daemon helper at
   `Contents/MacOS/net.mnmldsgn.t7fixer.helper` (built by
   `T7FixerHelper/build_helper.sh`) registered via
   `SMAppService.daemon(plistName:)`. The user sees one approval prompt the
   first time and subsequent fixes are silent. This is
   `SMAppServiceBridge.swift` + the entire `T7FixerHelper/` target.

   For this to work, the helper has to be signed with the same Developer ID
   Team ID as the host app, and the helper's `Info.plist`
   `SMAuthorizedClients` entry must reference that Team ID. The current
   `T7FixerHelper/Info.plist` has a `@TEAM_ID@` placeholder for this — must
   be replaced once a Developer ID is in hand.

**Do not delete the SMAppService path.** It's the future-state cleaner UX
and the helper builds correctly even without signing (it just won't load at
runtime). Keep it intact.

## File map

### Main app (`T7 Speed Restore/T7 Speed Restore/`)

- `T7_Speed_RestoreApp.swift` — `@main` entry point (default Xcode-generated).
- `ContentView.swift` — top-level SwiftUI view.
- `DropZoneView.swift` — the drag-and-drop target view.
- `T7Drive.swift` — value type holding the validated drive info plus the
  `T7DetectionError` enum (all user-facing error strings live here).
- `T7Detector.swift` — turns a dropped URL into a validated `T7Drive`.
  Reads `diskutil info -plist` and parses with `PropertyListSerialization`.
- `FixCoordinator.swift` — `@MainActor @Observable` state machine for the
  Fix button.
- `BenchmarkCoordinator.swift` — same shape, for the Benchmark button.
- `Benchmark.swift` — POSIX `open` + `fcntl F_NOCACHE` + `write` loop,
  time-boxed at 6s. Uses 1 MB chunks so the time-box overshoots by at most
  ~500 ms even at the bug's ~2 MB/s.
- `PrivilegeRouter.swift` — see "Two privilege paths" above.
- `OsascriptBridge.swift` — the current Fix runner. The bash script lives
  here as a Swift triple-quoted string (with caveats about escaping — see
  Gotchas).
- `SMAppServiceBridge.swift` — the signed-build Fix runner.
- `MountWatcher.swift` — installs and loads the LaunchAgent that keeps
  T7FIXER hidden across replug/login.
- `T7HelperProtocol.swift` — `@objc` XPC protocol + shared constants
  (`T7HelperConstants.machServiceName`, `partitionLabel`, `partitionSizeGB`,
  `fstabMarker`). Shared between main app and helper target.
- `T7_Speed_Restore.entitlements` — `com.apple.security.app-sandbox = false`.

### Helper target (`T7FixerHelper/`)

- `main.swift` — `NSXPCListener` loop (must be named `main.swift` for
  `swiftc -emit-executable` to accept top-level code).
- `T7HelperService.swift` — implements `T7HelperProtocol.performFix`. Same
  disk-operation logic as `OsascriptBridge`'s bash, in Swift.
- `DiskUtilRunner.swift` — `Process`-based wrapper around `/usr/sbin/diskutil`
  with stderr capture and typed errors.
- `FstabManager.swift` — atomic `/etc/fstab` rewrite. Tries direct write,
  falls back to `vifs`.
- `T7HelperProtocol.swift` — duplicate of the main-app file (the file is
  added to both targets at the filesystem level since the project uses
  `PBXFileSystemSynchronizedRootGroup` and per-target file membership for a
  shared file requires explicit pbxproj plumbing).
- `Info.plist` — the helper's Info.plist, embedded into the executable's
  `__TEXT,__info_plist` section by `build_helper.sh`. Contains the
  `SMAuthorizedClients` designated-requirement string with the `@TEAM_ID@`
  placeholder.
- `net.mnmldsgn.t7fixer.helper.plist` — the launchd plist. Copied to
  `Contents/Library/LaunchDaemons/` at build time by `build_helper.sh`.
- `Helper.entitlements` — `com.apple.security.app-sandbox = false`.
- `build_helper.sh` — the Run Script build phase. Compiles the helper via
  `xcrun swiftc -emit-executable`, embeds the Info.plist via `sectcreate`,
  copies the launchd plist, signs (if signing identity is set, which on
  ad-hoc builds it isn't).

### Project (`T7 Speed Restore.xcodeproj/`)

Modern Xcode 26+ project with `PBXFileSystemSynchronizedRootGroup` —
sources are auto-discovered from disk, not enumerated in the pbxproj.
The Run Script Build Phase (`Build Privileged Helper`, ID
`BB10000000000000000000A1`) is the only "non-default" part of the pbxproj.

Key build settings (target-level):
- `ENABLE_APP_SANDBOX = NO`
- `ENABLE_HARDENED_RUNTIME = YES`
- `ENABLE_USER_SCRIPT_SANDBOXING = NO` (required because `build_helper.sh`
  invokes `codesign` and `xcrun`, which the script sandbox blocks)
- `MACOSX_DEPLOYMENT_TARGET = 15.7`
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Swift 6 default; non-main
  work must be `nonisolated`)
- `CODE_SIGN_ENTITLEMENTS = "T7 Speed Restore/T7_Speed_Restore.entitlements"`
- `PRODUCT_BUNDLE_IDENTIFIER = "net.mnmldsgn.t7fixer"`

## Gotchas (the hard-won knowledge)

This section is the most important one to read before changing anything.
Every entry here cost a debugging cycle to discover.

### macOS disk concepts

- **An APFS volume's `ParentWholeDisk` is the synthesized APFS container
  disk, NOT the physical disk.** E.g., if you drop `/Volumes/MyT7` and it
  lives at `disk5s1`, `ParentWholeDisk` returns `disk5` (a virtual
  construct macOS creates to represent the APFS container's logical
  structure) — not `disk4` (the actual T7 hardware). To get the real
  physical disk, chase through:

  ```
  dropped volume  →  APFSContainerReference  →  container's APFSPhysicalStores[0].APFSPhysicalStore  →  that partition's ParentWholeDisk
  ```

  `T7Detector.swift` does this chain explicitly. **Do not** simplify it.

- **The right plist key inside `APFSPhysicalStores` array entries is
  `APFSPhysicalStore` (singular), not `DeviceIdentifier`.** I burned a
  debug cycle on this.

- **`diskutil list disk5` (synthesized) only shows APFS volumes inside the
  container, never GPT partitions.** To see the physical disk's GPT
  layout, use `diskutil list disk4` (the physical disk).

- **`diskutil addPartition <APFS-partition> ExFAT <name> <size>` fails with
  error `-69519` "a gap is required... is missing or too small" when the
  APFS container fills the disk all the way up to the GPT secondary header
  (which is the normal layout after a standard APFS format).** The fix is
  to do the operation explicitly in two steps:

  1. `diskutil apfs resizeContainer <container> <new_bytes>` to shrink
  2. `diskutil addPartition <APFS-partition> ExFAT <name> <size>` to add

  The script does this. **Do not** try to use the single-step form again.

- **`diskutil eraseVolume free Empty <partition>` is the right way to
  remove a partition** and return its space to free. Then
  `diskutil apfs resizeContainer <container> 0` grows the adjacent APFS
  container to absorb the freed space.

- **macOS auto-mounts a partition immediately after `diskutil addPartition`
  creates it.** That's why T7FIXER appears in Finder during the fix; the
  script unmounts it at the end.

- **`diskutil list` can briefly lag the actual partition table after
  `addPartition` returns.** Poll up to ~15 seconds with retries. The mount
  table (`/sbin/mount`) is faster to update; the script's primary
  partition-discovery uses mount, falling back to per-slot plist queries.

### macOS file permissions

- **`/etc/fstab` is not writable from osascript-elevated bash** (via
  `do shell script ... with administrator privileges`). Apple's
  `AuthorizationExecuteWithPrivileges` mechanism gives you uid 0 but
  strips some file-system capabilities. This is documented Apple behavior
  and they recommend SMAppService instead. We try anyway in the script as
  best-effort (it might work in a signed build) but rely on the
  per-user LaunchAgent for the actual cross-replug hiding.

- **`/etc/fstab` IS writable from `sudo`-launched shells.** That's the
  difference. If you're testing manually in Terminal, things work that
  won't work from the app.

- **The standard macOS tool for editing fstab is `/usr/sbin/vifs`.** It
  uses fcntl flock. It's interactive (opens vi), but you can supply your
  own editor via the `EDITOR` env var to script it. Doesn't bypass the
  osascript restriction unfortunately.

### NSAppleScript quirks

- **`NSAppleScript`'s `do shell script ... with administrator privileges`
  returns the script's stdout with classic-Mac `\r` (CR) line endings, not
  Unix `\n` (LF).** Splitting on `\n` will give you one giant line. Use
  `String.split(whereSeparator: \.isNewline)` instead.

- **User cancel of the auth prompt comes back as AppleScript error code
  `-128`** (`errAEEventNotPermitted`). Surface this as `.cancelled`, not
  a generic failure.

- **Swift's `"""..."""` doesn't interpret `\$`** so embedding bash inside
  Swift requires doubling backslashes for any `\$` (to get a literal
  `\$` in the bash output, write `\\$` in Swift). Avoid nested heredocs
  inside Swift multi-line strings — Xcode's "insufficient indentation"
  error pops up because heredoc bodies can't be indented but the closing
  Swift `"""` dictates indent. Use `printf` with `\\n` (which becomes
  `\n` in the script, which printf interprets as newline).

### Swift 6 / `@MainActor` default

- The project has `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. So every
  declaration is `@MainActor`-isolated unless explicitly marked
  `nonisolated`. All disk operations, XPC, NSAppleScript runs, and
  benchmark work happens off the main actor and must be marked
  `nonisolated`. Also note: `@objc` protocols default to MainActor too,
  which broke the XPC interface — `T7HelperProtocol` is marked
  `@objc nonisolated public protocol T7HelperProtocol`.

### Model-string variance

- **Newer T7 units / firmware report "PSSD T7", not "Samsung Portable SSD
  T7".** A real user's plain T7s were rejected because the matcher only knew
  the older strings. `T7Detector.isSamsungT7` must accept both naming
  families ("Portable SSD T7...", "PSSD T7...", "Samsung T7", plus the
  Shield/Touch variants), and the model check consults all three identity
  keys (`MediaName`, `IORegistryEntryName`, `DeviceModel`), not just the
  first non-empty one. For strings we still don't anticipate, the UI offers
  a "Use This Drive Anyway" override that re-runs detection with
  `allowUnrecognizedModel: true` (all other safety checks still apply).

### Detection refusal modes

The detector refuses with a clean error message in several cases. The
non-obvious ones:

- **Extra GPT partition after the APFS container.** Example: user has
  EFI + APFS + a "win" partition. `diskutil addPartition` can't insert
  T7FIXER between the APFS container and `win` (it would require moving
  the win partition, which the CLI doesn't expose — Disk Utility's GUI
  does it but uses internal frameworks). User must delete the trailing
  partition first.

- **Whole-disk APFS (no GPT).** Rare but possible. The drive has a single
  APFS container directly on the disk with no GPT wrapper. Detected when
  `apfsPartition == wholeDisk`. Refuse with "reformat to APFS with GPT
  scheme".

- **Less than ~26 GB free space.** We need 25 GB for the partition plus a
  small buffer. Read from the APFS container's `FreeSpace`. Below this
  threshold the shrink would fail.

## Debug log

The bash script writes step-by-step diagnostic info to
`/tmp/t7fixer-debug.log`. It **truncates on every run** (`: > "$DEBUG_LOG"`
at the top). The file is also `chmod 666`-ed so the user can read it
without sudo for support purposes. The path is intentionally not surfaced
in user-facing error messages anymore — it's a developer tool.

## Build & verify

```bash
# From the project directory:
xcodebuild -project "T7 Speed Restore.xcodeproj" \
    -scheme "T7 Speed Restore" \
    -configuration Debug \
    CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
    build
```

Built `.app` lives in
`~/Library/Developer/Xcode/DerivedData/T7_Speed_Restore-*/Build/Products/Debug/T7 Speed Restore.app`.

### Manual end-to-end test (requires a real Samsung T7)

1. Cmd+R in Xcode.
2. Drop the T7 onto the drop zone.
3. Click "Run Benchmark" — note the speed (probably slow if the bug is active).
4. Click "Restore Speed" — enter your admin password.
5. Click "Run Benchmark" again — speed should be ~500 MB/s.
6. Verify the partition state:

   ```bash
   diskutil list disk4   # substitute your physical T7 disk
   ls /Volumes/          # T7FIXER should NOT be there
   launchctl list | grep t7fixer   # the unmount watcher should be loaded
   ls -la ~/Library/LaunchAgents/net.mnmldsgn.t7fixer.unmount-watcher.plist
   ```

7. Unplug + replug the T7. T7FIXER should *not* appear in Finder (or
   appear and disappear within ~1s as the LaunchAgent reacts).
8. Inspect `/tmp/t7fixer-debug.log` to confirm what happened step-by-step.

### Manual cleanup if a test goes wrong

```bash
sudo diskutil unmount force /Volumes/T7FIXER 2>/dev/null
sudo diskutil eraseVolume free Empty disk4s3   # use the right slot
sudo diskutil apfs resizeContainer disk5 0     # grow APFS back

# Optional: remove the LaunchAgent
launchctl bootout gui/$(id -u)/net.mnmldsgn.t7fixer.unmount-watcher 2>/dev/null
rm -f ~/Library/LaunchAgents/net.mnmldsgn.t7fixer.unmount-watcher.plist
```

## Future Developer ID path

If/when Yann enrolls in the Apple Developer Program ($99/year) and gets a
Developer ID Application certificate:

1. In `T7FixerHelper/Info.plist`, replace `@TEAM_ID@` with the actual Team ID
   (e.g., `XXXXXXXXXX`).
2. In Xcode, set the Team ID on the main app target's Signing & Capabilities.
3. Build & sign with Developer ID Application.
4. `PrivilegeRouter` will automatically detect the Team ID via
   `SecCodeCopySelf` and switch to the `.smAppService` path. No code change
   needed.
5. Notarize the app: `xcrun notarytool submit ... --wait`.
6. Distribute the notarized `.app` or wrap in a `.dmg`.

In that mode, the user sees ONE approval prompt the first time they click
Fix (to allow the LaunchDaemon helper), and subsequent fixes are silent.

## User conventions (from Yann)

- Bundle ID prefix: `net.mnmldsgn.*` (preferred) or `com.mnmldsgn.*`
  (fallback). Never `com.yann.*`.
- No em dashes (`—`) in user-facing copy. Use periods + new sentences,
  commas, or parentheses instead. Internal docs (this file, code comments,
  commit messages) are fine.
