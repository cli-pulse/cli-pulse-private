cask "cli-pulse" do
  arch arm: "arm64"

  version "1.50.0"
  sha256 "355b8ba70a3f9b8bd6c8e12de22bbcfba09a70084e757343df107aed7bff7a43"

  # PINNED: the app update repo is `cli-pulse-distrib`, NOT `cli-pulse`, and the
  # owner segment stays `JasonYeYuhe` even after the org move — the shipped
  # in-app updater validates manifest URLs against that exact prefix, so a
  # "tidier" URL here would silently diverge from what every installed copy
  # already trusts.
  # No `verified:` — `brew audit` rejects it when the url and homepage share a
  # domain, which they do here (both github.com).
  url "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v#{version}/CLI-Pulse-#{version}-#{arch}.dmg"
  name "CLI Pulse"
  desc "Menu bar app for tracking AI coding tool usage, quota, and cost"
  homepage "https://github.com/JasonYeYuhe/cli-pulse-distrib"

  livecheck do
    url :url
    strategy :github_latest
    regex(/^app[._-]v?(\d+(?:\.\d+)+)$/i)
  end

  # The app ships its own signed+notarized updater (DEVID builds check the
  # manifest on focus, 24h throttle). Without this, brew would treat every
  # self-update as drift and offer to "reinstall" over a newer build — the two
  # updaters would fight, and the user would lose whichever race they didn't
  # know they were in.
  auto_updates true
  depends_on macos: :ventura

  app "CLI Pulse.app"

  # `uninstall` runs before the app bundle is removed, so the LaunchAgent gets
  # torn down while its program still exists. The bundled helper registers via
  # SMAppService under this label; leaving it behind means launchd keeps trying
  # to spawn a binary that is no longer there.
  uninstall launchctl: "yyh.CLI-Pulse.helper.agent",
            quit:      "yyh.CLI-Pulse"

  # Only `zap` may delete user data — `uninstall` must not, since a plain
  # `brew uninstall` is expected to be reversible.
  #
  # Two of these are easy to get wrong, and the first shipped wrong:
  #   - "CLIPulse" has NO space. `DailyUsageArchive.defaultRoot()` appends that
  #     literal, and the pet ledger/state share the directory — it holds the
  #     entire usage history. The cask originally listed "CLI Pulse", a path
  #     that does not exist, so `--zap` silently left everything behind and a
  #     reinstall came back with all of it.
  #   - the app-group defaults suite backs to a plist NEXT TO the group
  #     container, not inside it. Unsandboxed (which is what brew installs) that
  #     is ~/Library/Preferences/group.yyh.CLI-Pulse.plist, holding provider
  #     configs, helper status and cached collector results.
  zap trash: [
    "~/Library/Application Scripts/yyh.CLI-Pulse",
    "~/Library/Application Support/CLIPulse",
    "~/Library/Caches/yyh.CLI-Pulse",
    "~/Library/Containers/yyh.CLI-Pulse",
    "~/Library/Group Containers/group.yyh.CLI-Pulse",
    "~/Library/HTTPStorages/yyh.CLI-Pulse",
    "~/Library/LaunchAgents/yyh.CLI-Pulse.helper.agent.plist",
    "~/Library/Preferences/group.yyh.CLI-Pulse.plist",
    "~/Library/Preferences/yyh.CLI-Pulse.plist",
  ]
end
