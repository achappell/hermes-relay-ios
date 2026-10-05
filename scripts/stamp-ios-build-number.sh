#!/bin/sh
# Stamps the built app's CFBundleVersion from a per-user monotonic counter.
# CI supplies its own build number, so the counter is never touched there.
set -eu

if [ "${CI:-}" = "true" ]; then
    exit 0
fi

plist="${TARGET_BUILD_DIR:?}/${INFOPLIST_PATH:?}"
requested="${CURRENT_PROJECT_VERSION:?}"
state_dir="${HERMES_BUILD_NUMBER_DIR:?}"

baseline=$(cd "${PROJECT_DIR:?}" && xcrun agvtool what-version -terse)
for value in "$requested" "$baseline"; do
    case "$value" in
        ''|*[!0-9]*) echo "error: build version '$value' is not an integer" >&2; exit 1 ;;
    esac
done

mkdir -p "$state_dir"
counter="$state_dir/ios-build-number"

next=$(/usr/bin/lockf -k -t 30 "$counter.lock" /bin/sh -c '
    set -eu
    counter=$1 baseline=$2 requested=$3
    last=$baseline
    if [ -f "$counter" ]; then last=$(cat "$counter"); fi
    case "$last" in ""|*[!0-9]*) echo "error: corrupt build counter $counter" >&2; exit 1 ;; esac
    next=$((baseline + 1))
    if [ $((last + 1)) -gt "$next" ]; then next=$((last + 1)); fi
    if [ "$requested" -gt "$next" ]; then next=$requested; fi
    printf "%s\n" "$next" > "$counter.tmp"
    mv -f "$counter.tmp" "$counter"
    printf "%s\n" "$next"
' sh "$counter" "$baseline" "$requested")

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next" "$plist"
echo "Stamped CFBundleVersion $next"
