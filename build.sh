#!/bin/zsh
# Build AI File Organizer.
# Uses SwiftPM when full Xcode is installed; falls back to direct swiftc
# compilation with the command-line tools (works today, before Xcode).
set -e
cd "$(dirname "$0")"

if xcodebuild -version >/dev/null 2>&1; then
    swift build -c release
    echo "Built with SwiftPM: .build/release/FileOrganizer"
else
    mkdir -p .build/dev
    # Glob all sources so new files are never silently left out of this fallback.
    swiftc -parse-as-library -O \
        -o .build/dev/FileOrganizer \
        ${(f)"$(find Sources/FileOrganizer -name '*.swift' | sort)"}
    echo "Built with swiftc (no Xcode yet): .build/dev/FileOrganizer"
fi
