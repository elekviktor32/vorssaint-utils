#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Elek Viktor

# Fork-local: pulls upstream Vorssaint into this fork and proves the SSH tunnels
# feature still builds against it.
#
# A successful `git merge` proves nothing here. The feature adds a `.tunnels`
# case to several exhaustive switches (AppFeature, PanelSectionID, SettingsPage),
# and TunnelStrings switches over AppLanguage, so an upstream commit that adds a
# case or a language merges cleanly and then fails to compile. The build is the real gate, and a merge that does not pass it is
# rolled back rather than left sitting in the working tree.
#
#   ./Tools/sync-upstream.sh            merge, build, selftest
#   ./Tools/sync-upstream.sh --check    report what is waiting, change nothing
#   ./Tools/sync-upstream.sh --install  ... and install + launch when green
#   ./Tools/sync-upstream.sh --verify   run only the build gate, merge nothing
set -euo pipefail
cd "$(dirname "$0")/.."

# Files where this fork's own lines live. Nothing else can conflict: the feature
# is otherwise self-contained in Services/Tunnels, Core/TunnelStrings.swift,
# UI/MenuPanel/TunnelSection.swift and UI/Settings/TunnelSettings.swift.
TOUCHPOINTS=(
    Sources/Vorssaint/Core/FeatureCatalog.swift
    Sources/Vorssaint/Core/Defaults.swift
    Sources/Vorssaint/Core/FeaturePresets.swift
    Sources/Vorssaint/App/FeatureRuntime.swift
    Sources/Vorssaint/App/AppDelegate.swift
    Sources/Vorssaint/UI/MenuPanel/PanelLayout.swift
    Sources/Vorssaint/UI/MenuPanel/MenuPanelView.swift
    Sources/Vorssaint/UI/Settings/FeatureVisibilitySupport.swift
    Sources/Vorssaint/UI/Settings/SettingsView.swift
    Sources/Vorssaint/UI/Settings/SettingsDirectory.swift
    Sources/Vorssaint/UI/Settings/FeatureHubSettings.swift
    Sources/Vorssaint/UI/Settings/PanelLayoutEditor.swift
    Sources/Vorssaint/Support/SelfTest.swift
    Sources/Vorssaint/Core/AppInfo.swift
    Sources/Vorssaint/Services/Update/UpdateService.swift
)

CHECK_ONLY=0
INSTALL=0
VERIFY_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --install) INSTALL=1 ;;
        --verify) VERIFY_ONLY=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

if ! git remote get-url upstream >/dev/null 2>&1; then
    echo "No 'upstream' remote. Add it once:" >&2
    echo "  git remote add upstream https://github.com/vorssaintapp/vorssaint-utils.git" >&2
    exit 1
fi

# A merge into a dirty tree mixes your edits with upstream's and makes the
# rollback below unable to tell them apart.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean. Commit or stash first:" >&2
    git status --short >&2
    exit 1
fi

# $1: commit to roll back to on failure, empty when there is nothing to undo.
build_gate() {
    local rollback="$1"
    local undo=""
    [[ -n "$rollback" ]] && undo="Undo the merge with:  git reset --hard $rollback"

    echo
    echo "▸ Building… (a few minutes; the whole target is recompiled)"
    local log
    log=$(mktemp -t vorssaint-sync)
    if ! ./build.sh >"$log" 2>&1; then
        echo
        echo "✗ Build FAILED." >&2
        grep -E "error:" "$log" | head -20 >&2 || tail -20 "$log" >&2
        echo >&2
        echo "If upstream added a case to AppFeature, PanelSectionID or SettingsPage," >&2
        echo "the errors above name every switch missing a '.tunnels' branch — add them" >&2
        echo "and re-run with --verify. A new AppLanguage goes into the English-only" >&2
        echo "case list in Core/TunnelStrings.swift." >&2
        [[ -n "$undo" ]] && echo "$undo" >&2
        rm -f "$log"
        return 1
    fi

    local warnings
    warnings=$(grep -c "warning:" "$log" || true)
    if [[ "$warnings" != "0" ]]; then
        echo
        echo "✗ Build produced $warnings warning(s); this codebase builds clean." >&2
        grep "warning:" "$log" | head -10 >&2
        [[ -n "$undo" ]] && { echo >&2; echo "$undo" >&2; }
        rm -f "$log"
        return 1
    fi
    rm -f "$log"

    if ! ./build/Vorssaint --selftest; then
        echo
        echo "✗ Selftest FAILED." >&2
        [[ -n "$undo" ]] && echo "$undo" >&2
        return 1
    fi
    return 0
}

install_step() {
    if [[ "$INSTALL" == "1" ]]; then
        echo "▸ Installing…"
        ./build.sh --install
        open /Applications/Vorssaint.app
        echo "✓ Installed and launched."
    else
        echo "  Install with:  ./build.sh --install && open /Applications/Vorssaint.app"
    fi
}

# Re-running the build gate on its own: what you want after resolving a merge
# conflict by hand, when there is nothing left to fetch.
if [[ "$VERIFY_ONLY" == "1" ]]; then
    build_gate "" || exit 1
    echo
    echo "✓ 0 warnings, selftest green."
    install_step
    exit 0
fi

echo "▸ Fetching upstream…"
git fetch --quiet upstream

BEHIND=$(git rev-list --count HEAD..upstream/main)
if [[ "$BEHIND" == "0" ]]; then
    echo "✓ Already up to date with upstream."
    exit 0
fi

echo
echo "$BEHIND upstream commit(s) waiting:"
git --no-pager log --oneline --no-decorate HEAD..upstream/main | sed 's/^/  /'

# Which of the files carrying this fork's lines does upstream also touch? Only
# these can conflict, and knowing which ones turns a merge conflict from a
# surprise into an expected edit.
echo
CONTESTED=$(git diff --name-only HEAD...upstream/main -- "${TOUCHPOINTS[@]}")
if [[ -n "$CONTESTED" ]]; then
    echo "Upstream also touches these files, where this fork has lines:"
    echo "$CONTESTED" | sed 's|^Sources/Vorssaint/|  |'
else
    echo "Upstream touches none of the files this fork has lines in."
fi

# Exit status is the reliable signal: 0 clean, non-zero conflicts.
echo
if git merge-tree --write-tree HEAD upstream/main >/dev/null 2>&1; then
    echo "✓ Trial merge is clean."
else
    echo "⚠ Trial merge reports conflicts in:"
    # merge-tree exits non-zero on conflict, which under `set -e` with pipefail
    # would kill this script on the very path it exists to report. Capture it
    # first, so only the formatting runs in the pipeline.
    #
    # First line of the output is the tree oid; the file list ends at the blank
    # line, after which git appends its own "Auto-merging/CONFLICT" chatter.
    CONFLICTS=$(git merge-tree --write-tree --name-only HEAD upstream/main 2>/dev/null || true)
    echo "$CONFLICTS" | tail -n +2 | awk 'NF == 0 { exit } { print }' \
        | sed 's|^Sources/Vorssaint/|  |'
    echo
    echo "  Resolving these is almost always 'keep both sides': this fork's line"
    echo "  is a '.tunnels' case or a dictionary entry, and upstream's is about a"
    echo "  different feature."
fi

if [[ "$CHECK_ONLY" == "1" ]]; then
    echo
    echo "(--check: nothing was changed.)"
    exit 0
fi

BEFORE=$(git rev-parse HEAD)
echo
echo "▸ Merging…  (roll back at any point with: git reset --hard $BEFORE)"
if ! git merge --no-edit upstream/main; then
    echo
    echo "Merge stopped with conflicts. Resolve them, then:" >&2
    echo "  git add -A && git commit" >&2
    echo "  ./Tools/sync-upstream.sh --verify --install   # re-run the build gate" >&2
    echo "Or give up on this round with:" >&2
    echo "  git merge --abort" >&2
    exit 1
fi

build_gate "$BEFORE" || exit 1

echo
echo "✓ Merged $BEHIND commit(s), 0 warnings, selftest green."
install_step
echo "  Push the merge with:  git push"
