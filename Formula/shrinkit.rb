# Not published anywhere yet: there is no release tag, so this carries only a head spec and is
# installed with --HEAD, straight from the branch. A stable url and its sha256 go in beside it the
# day a version is tagged.
class Shrinkit < Formula
  desc "Compress and speed up macOS screen recordings"
  homepage "https://github.com/noxend/shrinkit"
  license "MIT"
  head "https://github.com/noxend/shrinkit.git", branch: "main"

  depends_on "ffmpeg"
  # launchd, plutil, pbs and osascript are all macOS, and the point of the thing is a Finder menu.
  depends_on :macos

  def install
    bin.install "shrinkit.sh" => "shrinkit"
    # The script reads these back as <keg>/share/shrinkit, beside its own bin directory. lib is
    # code rather than data: without it the command installs and then refuses to run.
    pkgshare.install "lib", "presets", "quick-action", "settings.conf"
  end

  def caveats
    <<~EOS
      Register the watcher, the Finder entries and the working folders:
        shrinkit setup

      brew cannot run anything before uninstalling, so undo that yourself first:
        shrinkit teardown
    EOS
  end

  test do
    ENV["SHRINKIT_DIR"] = testpath/"work"
    system formula_opt_bin("ffmpeg")/"ffmpeg", "-y", "-f", "lavfi",
           "-i", "testsrc=size=320x240:rate=30:duration=2",
           "-pix_fmt", "yuv420p", testpath/"clip.mov"
    system bin/"shrinkit", "--no-notify", "--no-notify-start", testpath/"clip.mov"
    assert_path_exists testpath/"clip.mp4"
  end
end
