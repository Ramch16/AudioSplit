# Homebrew cask for AudioSplit.
#
# Publish by copying this into a tap (e.g. Ramch16/homebrew-tap as
# Casks/audiosplit.rb) and filling in the sha256 of the released DMG:
#
#   shasum -a 256 dist/AudioSplit-1.0.dmg
#
# The cask deliberately does not exist until there is a *notarized* DMG behind
# it. Homebrew installs bypass the Gatekeeper prompt a user would otherwise see,
# so shipping an unnotarized build this way hands people an app macOS would
# have refused, without telling them.
cask "audiosplit" do
  version "1.0"
  sha256 "REPLACE_WITH_SHA256_OF_THE_RELEASED_DMG"

  url "https://github.com/Ramch16/AudioSplit/releases/download/v#{version}/AudioSplit-#{version}.dmg"
  name "AudioSplit"
  desc "Per-app audio output routing"
  homepage "https://github.com/Ramch16/AudioSplit"

  # Process taps need macOS 14.4.
  depends_on macos: ">= :sonoma"

  app "AudioSplit.app"

  uninstall quit: "com.audiosplit.AudioSplit"

  # Routes and the remote pairing code. Left behind on uninstall unless the
  # user asks for a zap, so reinstalling does not lose their setup.
  zap trash: [
    "~/Library/Application Support/AudioSplit",
    "~/Library/Preferences/com.audiosplit.AudioSplit.plist",
  ]

  caveats <<~EOS
    AudioSplit needs permission to capture audio. macOS returns silence rather
    than an error when that permission is missing, so if routes show as Active
    but nothing moves, grant access under:

      System Settings > Privacy & Security

    AudioSplit is not sandboxed, which is why it is not on the Mac App Store:
    Core Audio process taps and aggregate devices do not work inside the App
    Sandbox.
  EOS
end
