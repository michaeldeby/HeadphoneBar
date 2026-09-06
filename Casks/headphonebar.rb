cask "headphonebar" do
  version "0.1.0"
  sha256 "843da1d807e2a043c67b66acc2bf616aa587553c5a9178573e17ee92654db613"

  url "https://github.com/michaeldeby/HeadphoneBar/releases/download/v#{version}/HeadphoneBar-#{version}-macOS-universal.zip"
  name "HeadphoneBar"
  desc "Menu bar headphone controls and Sennheiser BTD 700 settings"
  homepage "https://github.com/michaeldeby/HeadphoneBar"

  depends_on macos: ">= :sonoma"

  app "HeadphoneBar.app"

  uninstall quit: "local.headphonebar.app"

  zap trash: "~/Library/Preferences/local.headphonebar.app.plist"
end
