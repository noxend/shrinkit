cask "shrnkit" do
  version "3.1.0"
  sha256 "e4a73819a40a22f484a119ebc3e02e4992c3610a86f9442de561f841cce94d27"

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
