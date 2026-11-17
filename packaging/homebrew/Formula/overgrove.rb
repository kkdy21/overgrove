# Template for Formula/overgrove.rb in kkdy21/homebrew-tap (ADR-0027 in kkdy21/overgrove).
# At release time, copy it to the tap, set `url` and `sha256` for the new tag, and add the bottle block that the
# tap's bottle workflow prints (docs/process/release.md). Review changes to the build steps here first.
class Overgrove < Formula
  desc "Read-only macOS Git client for repositories with many worktrees"
  homepage "https://github.com/kkdy21/overgrove"
  url "https://github.com/kkdy21/overgrove/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"
  head "https://github.com/kkdy21/overgrove.git", branch: "main"

  # The tap's bottle workflow prints this block for each release. One arm64_sonoma bottle covers macOS 14 and later
  # on Apple silicon; anything else builds from source.
  # bottle do
  #   root_url "https://github.com/kkdy21/homebrew-tap/releases/download/overgrove-0.1.0"
  #   sha256 arm64_sonoma: "<sha256 of overgrove-0.1.0.arm64_sonoma.bottle.tar.gz>"
  # end

  # The app runs on macOS 14 or later. Building from source needs Xcode 26, which needs macOS 15.6 or later.
  depends_on xcode: ["26.0", :build]
  depends_on macos: :sonoma

  deny_network_access!

  def install
    # Use the Xcode that `depends_on xcode:` found, even when xcode-select points at the Command Line Tools.
    ENV["DEVELOPER_DIR"] = ENV["HOMEBREW_DEVELOPER_DIR"]

    xcodebuild "-project", "Overgrove.xcodeproj",
               "-scheme", "Overgrove",
               "-configuration", "Release",
               "-destination", "platform=macOS,arch=#{Hardware::CPU.arch}",
               "-derivedDataPath", buildpath/"DerivedData",
               "ARCHS=#{Hardware::CPU.arch}",
               # Ad-hoc signing ("Sign to Run Locally"): no team, no certificate.
               "CODE_SIGN_STYLE=Manual",
               "CODE_SIGN_IDENTITY=-",
               "DEVELOPMENT_TEAM=",
               # The Swift compiler sandboxes macro plugins (@Observable) with sandbox-exec, which cannot nest
               # inside Homebrew's build sandbox. Homebrew's sandbox still confines the whole build.
               "OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox",
               # A newer Xcode can add warnings; they should not stop an install. CI still treats them as errors.
               "SWIFT_TREAT_WARNINGS_AS_ERRORS=NO",
               "GCC_TREAT_WARNINGS_AS_ERRORS=NO",
               "build"
    prefix.install buildpath/"DerivedData/Build/Products/Release/Overgrove.app"
  end

  def caveats
    <<~EOS
      Overgrove.app is in:
        #{opt_prefix}/Overgrove.app

      To see it in ~/Applications, add a link. The link keeps working after upgrades:
        mkdir -p ~/Applications
        ln -sfn #{opt_prefix}/Overgrove.app ~/Applications/Overgrove.app

      Spotlight may not list a link. If you want that, copy the app instead,
      and copy it again after each upgrade:
        rm -rf ~/Applications/Overgrove.app
        ditto #{opt_prefix}/Overgrove.app ~/Applications/Overgrove.app
    EOS
  end

  test do
    app = prefix/"Overgrove.app"
    plist = app/"Contents/Info.plist"
    assert_path_exists app/"Contents/MacOS/Overgrove"
    assert_equal "io.github.kkdy21.overgrove",
                 shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' #{plist}").chomp
    unless version.head?
      assert_equal version.to_s,
                   shell_output("/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' #{plist}").chomp
    end
    # The app has no command-line mode, so check the bundle and its signature without launching it.
    assert_match "valid on disk", shell_output("codesign --verify --deep --strict --verbose=2 #{app} 2>&1")
    assert_match(/flags=0x\h+\(adhoc,runtime\)/, shell_output("codesign --display --verbose=2 #{app} 2>&1"))
  end
end
