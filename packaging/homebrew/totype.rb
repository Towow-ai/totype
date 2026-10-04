# Homebrew cask for Totype, published in the Towow-ai/homebrew-tap repository
# as Casks/totype.rb: `brew install --cask towow-ai/tap/totype`.
#
# Before each release:
#   1. Set `version` to the released version.
#   2. Replace the sha256 below with the digest of the dmg, taken from the
#      SHA256SUMS file attached to the GitHub Release.
#
# Homebrew's main cask repository no longer accepts apps that are not
# notarized, so this cask is meant for a third-party tap. The app is signed
# ad-hoc and not notarized; macOS still asks for a manual approval on first
# launch (see the caveats).
cask "totype" do
  version "0.5.0"
  sha256 "8bf2cedcc5242c448ed53f93cfe5532450867feea9dfa7575c5cd4eb43d54b9c"

  url "https://github.com/Towow-ai/totype/releases/download/v#{version}/Totype-#{version}-arm64.dmg"
  name "Totype"
  desc "Voice input method for macOS that inserts your words verbatim"
  homepage "https://github.com/Towow-ai/totype"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Totype.app"

  zap trash: [
    "~/Library/Application Support/Totype",
    "~/Library/Preferences/ai.towow.totype.plist",
  ]

  caveats <<~EOS
    Totype is not notarized by Apple. The first time you open it, macOS blocks it:
    open System Settings > Privacy & Security, scroll to the bottom and click
    "Open Anyway" next to the Totype message. Or remove the quarantine flag:

      xattr -dr com.apple.quarantine /Applications/Totype.app

    Then grant Microphone, Accessibility and Input Monitoring. After an update
    the three grants may need to be added again.
  EOS
end
