# HeadphoneBar for Raycast

Local Raycast extension for macOS. Requires the HeadphoneBar build containing
Raycast support, installed in Applications and opened once. The v0.1.0 release
does not yet support these commands.

Commands:
- **ANC On** enables full ANC on MOMENTUM 4, Noise Cancelling on supported Sony models, or Quiet on Bose.
- **ANC Off** disables ANC when an Off mode is available.
- **Transparency On** selects full transparency on MOMENTUM 4, Ambient on Sony, or Aware on Bose.
- **Use Bluetooth Audio** selects the headphone’s direct Mac audio output.
- **Use BTD 700 Audio** selects a connected dongle for supported Sennheiser headphones. On MOMENTUM 4 it uses the same peer-switch routine as the app, retaining the Mac control connection.
- **Open HeadphoneBar** opens the headphone controls window (ANC and EQ).
- **BTD 700 Advanced** opens the dongle sound mode and audio format panel.
- **Refresh Headphones** opens HeadphoneBar and requests fresh settings.

The extension uses HeadphoneBar's `headphonebar://open`, `headphonebar://advanced`,
and `headphonebar://refresh` links. Direct commands send a short-lived local request to HeadphoneBar. HeadphoneBar performs the change and reads back the result; Raycast only reports success after confirmation. Commands fail clearly for unsupported modes, unavailable devices, changed connections, or mismatched readback. Legacy Sony models without mode readback are not supported by direct noise commands. Bose requires an unambiguous Quiet/Aware/Off mode as appropriate. No network service or account is required.

## Local installation

```sh
cd raycast
npm ci
npm run dev
```

Raycast imports the extension. Search for the commands above. You can assign aliases
and hotkeys in Raycast Settings → Extensions. The development watcher can then be
stopped with Ctrl-C; run it again after editing the extension.

Validation: `npm run typecheck && npm run build`.
This extension has not been submitted to the Raycast Store.
