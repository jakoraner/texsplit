#!/bin/sh
# Build and run the marks harness (Harness/main.swift) against Marks.swift.
set -e
cd "$(dirname "$0")"
mkdir -p .build
swiftc -O Sources/TeXSplit/Marks.swift Sources/TeXSplit/Extras.swift Harness/main.swift -o .build/marks-harness
.build/marks-harness
