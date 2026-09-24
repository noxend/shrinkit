cask "shrnkit" do
  version "3.0.0"
  sha256 "260d1fc4c2b45adcd962d5da278ad8bd15195524eebe92e84175e9ec3420925b"

  url "https://github.com/noxend/shrinkit/archive/refs/tags/v#{version}.tar.gz"
  name "shrinkit"
  desc "Compresses and speeds up screen recordings"
  homepage "https://github.com/noxend/shrinkit"

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
