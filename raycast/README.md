# HeadphoneBar for Raycast

Local Raycast extension for macOS. Requires the HeadphoneBar build containing
Raycast support, installed in Applications and opened once. The v0.1.0 release
does not yet support these commands.

Commands:
- **Open HeadphoneBar** opens the headphone controls window (ANC and EQ).
- **BTD 700 Advanced** opens the dongle sound mode and audio format panel.
- **Refresh Headphones** opens HeadphoneBar and requests fresh settings.

The extension uses HeadphoneBar's `headphonebar://open`, `headphonebar://advanced`,
and `headphonebar://refresh` links. It does not connect to Bluetooth independently
or directly change headphone settings. No network service or account is required.

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
