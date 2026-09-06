#!/usr/bin/env python3
"""Generate a checksum-pinned Homebrew cask from the actual release ZIP."""
import hashlib
import pathlib
import re
import sys

version = pathlib.Path("VERSION").read_text().strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("Invalid VERSION")
archive = pathlib.Path(f"dist/release/HeadphoneBar-{version}-macOS-universal.zip")
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
output = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "Casks/headphonebar.rb")
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(f'''cask "headphonebar" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/michaeldeby/HeadphoneBar/releases/download/v#{{version}}/HeadphoneBar-#{{version}}-macOS-universal.zip"
  name "HeadphoneBar"
  desc "Menu bar headphone controls and Sennheiser BTD 700 settings"
  homepage "https://github.com/michaeldeby/HeadphoneBar"

  depends_on macos: ">= :sonoma"

  app "HeadphoneBar.app"

  uninstall quit: "local.headphonebar.app"

  zap trash: "~/Library/Preferences/local.headphonebar.app.plist"
end
''')
print(f"Generated {output} with SHA-256 {digest}")
