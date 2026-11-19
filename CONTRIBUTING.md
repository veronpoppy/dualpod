# Contributing to DualPod

DualPod is maintained by one person with two HomePod minis (1st and 2nd generation). Every pull request is built and tried on those speakers before it's merged, so small, focused changes are the easiest to accept. Other hardware, such as the full-size HomePod, can't be tested here, so reports from it are welcome but may not be fixable.

## Reporting a bug

Search the existing issues, open and closed, first. Then open a new issue with the Bug report form, which asks for:

- The diagnostics. Click the DualPod icon in the menu bar, choose Settings…, open General, and click Copy Diagnostics under Troubleshooting. The text goes to the clipboard. Its first lines give the DualPod and macOS versions.

  Check the text before pasting it into the issue. DualPod tries to replace IP addresses, device IDs, `.local` host names, your home folder, and the names of the speakers it currently sees with placeholders, but it can miss some. Examples are speaker names of one character, speakers it no longer sees, and a home folder name with a space in it. Replace anything it missed by hand.
- The HomePod model and software version (Home app → the HomePod's settings).
- Your Mac model (Apple menu → About This Mac).
- What you did, what you expected, and what happened.

## Suggesting a feature

Open an issue with the Feature request form before writing code, so you and the maintainer can agree on the scope. DualPod only supports HomePod, so requests for other speakers will be closed.

## Sending a pull request

### When to open an issue first

Open an issue before writing code when your change:

- adds a feature,
- changes how DualPod behaves (a new setting, a different default, a menu item that does something else), or
- changes airplay-cli or audiotee (see below).

You can skip the issue for a bug fix (DualPod not doing what it already says it does) or a typo fix, unless it changes airplay-cli or audiotee. If you're not sure, open an issue.

airplay-cli (in `airplay-cli/`) sends the audio to the HomePods over AirPlay, and audiotee (in `audiotee/`) captures the Mac's audio. `scripts/fetch-deps.sh` clones both at pinned commits and applies DualPod's own changes, kept as `.diff` files in `patches/`. A release can only be packaged when `airplay-cli/` and `audiotee/` match the pinned commits plus these patches. So a change to either one ships as a new or edited `.diff` file in `patches/`, and in the issue you and the maintainer agree on how to make it.

### Build and test

You need an Apple silicon Mac on macOS 14.4 or later, and Xcode or the Command Line Tools.

Match the style of the code around your change, and write comments that explain why, not what.

1. Fork and clone the repository, switch to the `dev` branch, then build from its root:

   ```bash
   git switch dev
   zsh scripts/fetch-deps.sh
   zsh app/build.sh
   ```

   This makes `app/DualPod.app`. Quit DualPod if it's running, then open that copy. It may offer to update the background helper (the background process that runs airplay-cli and audiotee), which needs an administrator password. Opening your installed copy of DualPod later offers to switch the helper back.

2. Run the tests. They don't need HomePods or a network, but they use `tools/stereotool`, which step 1 builds. Each shell test takes an empty scratch folder as its only argument, for example `zsh tools/glow_test.sh "$(mktemp -d)"`. To run all of them, including the Python one:

   ```bash
   failed=0
   for t in tools/*_test.sh; do
     zsh $t "$(mktemp -d)" || { echo "FAILED: $t"; failed=1; }
   done
   python3 -I tools/split_test.py "$(mktemp -d)" tools/stereotool || { echo "FAILED: split_test.py"; failed=1; }
   (( ! failed ))
   ```

   It prints `FAILED:` and the test name for each failure, and the last line exits with a non-zero status if any failed.

3. If you have HomePods, play audio through them and check the part you changed. If you can't, say so in the pull request, and the maintainer will test it.

4. Check that your commits carry no personal data. Logs and test notes easily pick up your home folder path, local IP addresses, MAC addresses or HomePod device IDs. Turn on the pre-push check once, and every push runs it (it needs zsh, which macOS has by default):

   ```bash
   git config core.hooksPath .githooks
   ```

   To check by hand, run `zsh scripts/check-private.sh origin/dev`. It scans the lines your commits add and their messages. If a flagged line is fine, such as a documented example, add `check-private: allow` to it.

### Send it

Push a branch to your fork and open the pull request against `dev`. `main` only changes when a version is released, so a pull request against `main` will be retargeted. In the description, say what changed and which HomePod models and software versions you tested with, if any. Link the issue if there is one. For a bug fix without an issue, include what [Reporting a bug](#reporting-a-bug) asks for: the diagnostics, the HomePod model and software version, and what you did, expected, and saw. Keep "Allow edits from maintainers" on, so small fixes can be pushed to your branch instead of going back and forth.

## License

DualPod is licensed under the GNU General Public License, version 3. By contributing, you agree that your contribution is licensed under the same license.
