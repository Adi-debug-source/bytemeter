class Bytemeter < Formula
  desc "Menu bar app that counts every byte your Mac sends and receives"
  homepage "https://github.com/Adi-debug-source/bytemeter"
  url "https://github.com/Adi-debug-source/bytemeter/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "2dcc28cc943c47d474c73445dc270e18f8f6d5fd70ce9b203c0712508d4d2a8b"
  license "MIT"

  depends_on macos: :ventura

  def install
    # Built here, on the Mac it will run on, so the app carries no quarantine
    # mark. Gatekeeper's first-launch check is triggered by that mark, which
    # is why this works for an app that is only ad hoc signed and a download
    # does not. Homebrew builds inside a sandbox and SwiftPM's own sandbox
    # cannot start inside another one, hence --disable-sandbox.
    system "./install.sh", "--bundle-only", prefix, "--disable-sandbox"

    # What bytemeter-setup needs later: the script and the login item template.
    libexec.install "install.sh", "Scripts"

    # The same install.sh a git clone uses, given the app Homebrew has built,
    # so it copies that app rather than building it again.
    (bin/"bytemeter-setup").write <<~SH
      #!/bin/bash
      exec "#{libexec}/install.sh" --app "#{opt_prefix}/Bytemeter.app" "$@"
    SH
    chmod 0755, bin/"bytemeter-setup"
  end

  def caveats
    <<~EOS
      To finish, run:
        bytemeter-setup

      It copies Bytemeter.app to ~/Applications, starts it, and adds a login
      item so it starts again when you log in. Homebrew cannot write to your
      home folder itself, which is why this is a second step.

      Run it again after `brew upgrade bytemeter`. To remove Bytemeter (your
      usage history is kept):
        bytemeter-setup --uninstall
        brew uninstall bytemeter
    EOS
  end

  test do
    app = prefix/"Bytemeter.app"
    assert_predicate app/"Contents/MacOS/Bytemeter", :executable?
    assert_equal version.to_s,
      shell_output("/usr/bin/plutil -extract CFBundleShortVersionString raw -o - '#{app}/Contents/Info.plist'").strip
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", app
    # The wrapper, the script and the template still fit together. A dry run
    # changes nothing and needs no running app.
    assert_match "would install the app", shell_output("#{bin}/bytemeter-setup --dry-run")
  end
end
