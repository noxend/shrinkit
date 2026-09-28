cask "shrnkit" do
  version "3.2.0"
  sha256 "bbc3df18deba9b0f680a3416a5920ecfdf5cdd8c285e1f4d10ff4870ef00f2c4"

  url "https://github.com/noxend/shrinkit/archive/refs/tags/v#{version}.tar.gz"
  name "shrinkit"
  desc "Compresses and speeds up screen recordings"
  homepage "https://noxend.github.io/shrinkit/"

  depends_on formula: "ffmpeg"

  # Script stanzas rather than install steps: steps run in a sandbox where launchd refuses to
  # register an agent.
  installer script: {
    executable: "shrinkit-#{version}/shrinkit.sh",
    args:       ["setup"],
  }
  binary "shrinkit-#{version}/shrinkit.sh", target: "shrinkit"

  uninstall script: {
    executable: "shrinkit-#{version}/shrinkit.sh",
    args:       ["teardown"],
  }

  zap trash: "~/Library/Application Support/shrinkit"
end
