# HeadphoneBar

Open-source headphone controls, licensed under [MIT](LICENSE).

| Edition | Status |
| --- | --- |
| **macOS** | Available as a preview · macOS 14+ · Apple Silicon and Intel |
| **Omarchy / Linux** | [Coming soon](docs/omarchy.md) · no Linux build yet |

A native macOS menu bar app for connected Sennheiser, Sony, and Bose headphones. Requires macOS 14 or later. Local Bluetooth and audio-output control; no account or server.

When a BTD 700 USB audio output is present, **Use BTD 700** switches the macOS default audio output to it. **Use Bluetooth** switches back to the selected headphones when their direct Bluetooth audio output is available. Headphones must already be paired with the dongle. ANC/EQ still use the direct Mac Bluetooth connection; this does not forward headphone commands through USB. Apps with their own output selection may need to follow the system default. Dongle changes are detected on refresh and every five seconds.

## Install macOS

Download the `.pkg` installer from [Releases](https://github.com/michaeldeby/HeadphoneBar/releases).
It installs `HeadphoneBar.app` in `/Applications`. Alternatively, download the ZIP
and move the app to Applications. Release assets include SHA-256 checksums.

Preview builds are ad-hoc signed and **not notarized by Apple**. If macOS blocks
launch, use **System Settings → Privacy & Security → Open Anyway** after verifying
the download and deciding you trust this release. No security settings need to be
disabled. Apple Developer signing/notarization is not configured yet.

### Homebrew

Install the macOS preview using the project’s Homebrew tap:

```sh
brew tap michaeldeby/headphonebar https://github.com/michaeldeby/HeadphoneBar.git
brew install --cask michaeldeby/headphonebar/headphonebar
```

This is a project-maintained tap, not an entry in Homebrew's official cask catalog.
The release PR must be merged before `brew upgrade` can see a new version.

## Build and run

```sh
./scripts/build-app.sh
open dist/HeadphoneBar.app
```

Builds with Apple's Swift command line tools; full Xcode is not required. The output is ad-hoc signed for local use, not notarized for distribution. The bundle runs in the menu bar without a Dock icon.

Pair/connect headphones in macOS Bluetooth settings, launch the app, grant Bluetooth access, then click the headphone menu bar icon. One connected recognized headset is selected automatically; with multiple headsets, choose one explicitly. Only read requests run on connection. Settings change when you use a control. EQ edits are applied together using **Apply EQ**.

## Current adapters

| Headphones | Implemented controls | Limits |
| --- | --- | --- |
| Sennheiser MOMENTUM 4 | Battery, ANC off/adaptive/custom, transparency, EQ | Uses the M4 Companion protocol client. Other Sennheiser models currently support BTD 700 audio selection only. |
| Sony with v2 control service (e.g. WH-CH720N, WH-1000XM5) | Noise cancelling/off/ambient, ambient level, battery, six EQ values including Clear Bass | EQ appears only after a valid read. Single-battery read only. Model/firmware hardware verification still required. |
| Sony with legacy v1 service (e.g. WH-1000XM3/XM4) | Noise cancelling/off/ambient commands | Current mode cannot be shown reliably. No EQ/battery queries; v2 battery opcode means power off on v1. |
| Bose with AudioModes over BLE (target: QC Ultra Gen 1) | Battery, device-defined Quiet/Aware/custom modes | No EQ or continuous ANC slider yet. Classic and BLE names must match exactly. Multiple identical names are rejected. Other Bose generations need hardware validation. |

MOMENTUM 4 battery, noise controls and EQ readback have been exercised on hardware. EQ activation now explicitly enables Equalizer sound mode; audible EQ behaviour still needs user confirmation. BTD 700 output switching, Standard/Gaming modes and USB format changes have been verified on hardware. Sony and Bose adapters still require hardware validation. Compilation and wire-format tests alone do not establish model compatibility.

Names are used to select an adapter; Sony additionally verifies its advertised protocol service before issuing commands. Renamed devices with no recognizable model name appear as unsupported audio devices. The application does not identify every model using manufacturer IDs yet.

Paired-device discovery runs every five seconds. Settings are read when opening the panel, selecting a device, refreshing, or completing a change. Errors clear the controls to avoid displaying stale values. Competing phone/desktop control apps can hold the control connection; close those apps if requests time out.

## Verification

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift run --disable-sandbox --cache-path "$PWD/.build/cache" HeadphoneProtocolTests
```

Tests cover known wire bytes, escaping, fragmented/coalesced Sony frames, Bose segmentation, malformed lengths/checksums, and conservative model detection.

For hardware validation: read the initial state; change each supported mode and verify using the headphone/official app; apply a small EQ change and read it back; disconnect while reading and confirm the error state; reconnect and refresh; test selection with two devices connected. Record exact model and firmware before expanding the compatibility table.

## Source acknowledgments

MIT license notices are in `ThirdPartyNotices` and included in the app bundle.

- [M4 Companion](https://github.com/Zhengyang-Liu/m4-companion), commit `4f263c7ca1ab04fd8ec62b8b35e1f2ff46064547`: vendored MomentumCore and MomentumBluetooth sources. Local transport instrumentation logs connection stages (without addresses or payloads); `--diagnose-momentum` forces fresh service discovery to investigate connection failures.
- [SonyBridge](https://github.com/AmitRajput-Dev/SonyBridge), commit `8c81a2775a76097f4938fbc835411bd59088014c`: Swift protocol implementation adapted from framing/constants/commands. No upstream UI or artwork included.
- [bozo](https://github.com/NerdySouth/bozo), commit `db07cad042093a4abcfb37c3f31ab6ace6137d4a`: Bose BMAP/BLE protocol reference for the Swift adapter.

HeadphoneBar is an independent project, not affiliated with Sennheiser, Sony, or Bose.

## MOMENTUM connection investigation

During initial testing, the control connection failed with Bluetooth error 913 and BLE writes reported insufficient encryption. Removing the saved MOMENTUM 4 pairing and pairing again restored control access. This observation does not establish the cause of all connection timeouts.

The diagnostic launch argument `--diagnose-momentum` requests fresh service discovery before opening the control channel. Connection-stage logs use subsystem `local.headphonebar.app`, category `MomentumConnection`. This is diagnostic instrumentation, not a verified timeout fix. No settings are changed by discovery or initial reads.

### BTD 700 compatibility

The BTD 700 manual states compatibility with all Bluetooth headphones. HeadphoneBar exposes its output selector only for recognised Sennheiser Bluetooth families, including MOMENTUM (over-ear and True Wireless), ACCENTUM, HDB 630, CX, HD Bluetooth, PXC, MM, SPORT True Wireless and IE 80S BT, plus explicitly Sennheiser-named paired audio devices. Custom names without a recognised model or brand cannot be identified automatically.

MOMENTUM 4 retains automatic peer switching that preserves this Mac. Other models currently select an already-connected dongle's audio output only; their ANC/EQ and automatic peer switching are not implemented. These capabilities must not be inferred from dongle audio compatibility.

Sources:
- [BTD 700 manual](https://cdn.sennheiser-hearing.com/product-documents/product-downloads/btd-700/Instruction%20manual%20BTD%20700/Instruction_manual_BTD_700.pdf)
- [MOMENTUM 5 / BTD 700 bundle](https://us.sennheiser-hearing.com/products/momentum-5-wireless-and-btd-700-set)
- [HDB 630 package contents](https://spares.sennheiser-hearing.com/catalog/product/700445-hdb-630)

### BTD 700 sound modes

The **BTD 700 Advanced…** panel reads and sets Standard, Gaming and Broadcast directly over the dongle's vendor USB HID interface. It verifies mode changes by querying the dongle again. Broadcast uses LE Audio and the dongle's existing Auracast public/private configuration; use Sennheiser Dongle Control to edit broadcast credentials. Returning from Broadcast selects Bluetooth Classic. Only one connected dongle is supported for control.

Standard → Gaming → Standard was verified on the connected hardware. Broadcast has not been exercised in the hardware test. Protocol references: [btd700ctl](https://github.com/sobalap/btd700ctl), [Sennheiser Dongle Control research](https://github.com/sinchichou/Sennheiser-Dongle-Control).

The Advanced panel also offers the USB audio formats reported by Core Audio, matching Audio MIDI Setup. A 16-bit/44.1 kHz change and restoration to 24-bit/96 kHz were verified. Bluetooth transmission quality also depends on the codec and headphones.

## Release automation

GitHub Actions runs protocol tests and builds a universal app, ZIP and `.pkg` on
pull requests and pushes to `main`. To publish a preview, update `VERSION` through
a reviewed PR, merge it, then tag that commit (`v0.1.0`, for example) and push the
tag. The release workflow verifies the tag matches `VERSION` and belongs to
`main`, publishes versioned assets, and generates `headphonebar.rb` with the ZIP checksum.
To update the Homebrew tap, download that asset into `Casks/headphonebar.rb` and
submit it in a draft PR for review. No workflow PR-approval permissions are required.

Build packages locally with `./scripts/package-macos.sh`. Signing certificates,
notarization credentials and firmware images are not stored in the repository.
Third-party license notices remain in `ThirdPartyNotices` and the app bundle.
