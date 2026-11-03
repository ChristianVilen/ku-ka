#!/bin/bash
# Run after a full test run. Fails when a test takes 0.1 s or more and
# scripts/slow-tests-allowed.txt gives no reason for it, or when AGENTS.md
# is over 150 lines.
#
# Usage: scripts/check-tests.sh [result.xcresult]
# Without an argument, it reads the newest test result in the DerivedData
# folder of this checkout.
set -eu

cd "$(dirname "$0")/.."
limit=0.1
allowed=scripts/slow-tests-allowed.txt
failed=0

result=${1:-}
if [ -z "$result" ]; then
    project="$PWD/KuKa.xcodeproj"
    for info in ~/Library/Developer/Xcode/DerivedData/KuKa-*/info.plist; do
        if [ "$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$info" 2>/dev/null)" = "$project" ]; then
            result=$(/bin/ls -dt "$(dirname "$info")"/Logs/Test/*.xcresult 2>/dev/null | head -1)
        fi
    done
fi
[ -n "$result" ] || { echo "No test result found. Run the tests, or pass a .xcresult path." >&2; exit 2; }

# Each test that takes at least the limit, as "Class/testName() seconds".
slow=$(xcrun xcresulttool get test-results tests --path "$result" | jq -r --argjson limit "$limit" '
    [.. | objects | select(.nodeType == "Test Case" and .result != "Skipped" and .durationInSeconds >= $limit)]
    | sort_by(-.durationInSeconds)[] | "\(.nodeIdentifier) \(.durationInSeconds * 1000 | round / 1000)"')

while read -r test seconds; do
    [ -n "$test" ] || continue
    if ! grep -q "^$test[[:space:]]" "$allowed"; then
        echo "Slow test without a reason in $allowed: $test ($seconds s)"
        failed=1
    fi
done <<< "$slow"

# An entry for a test that is fast now only makes the list longer.
while read -r test _; do
    case "$test" in ''|'#'*) continue ;; esac
    grep -q "^$test " <<< "$slow" || echo "No longer slow, remove it from $allowed: $test"
done < "$allowed"

lines=$(wc -l < AGENTS.md)
if [ "$lines" -gt 150 ]; then
    echo "AGENTS.md has $lines lines. Keep it at 150 or fewer."
    failed=1
fi

exit $failed
