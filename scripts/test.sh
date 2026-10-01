#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$project_dir/.build"
swiftc -swift-version 5 -parse-as-library "$project_dir"/Sources/Core/*.swift "$project_dir/Tests/CoreTests.swift" -framework AppKit -o "$project_dir/.build/MenuCraftTests"
"$project_dir/.build/MenuCraftTests"
swiftc -swift-version 5 -parse-as-library "$project_dir/Sources/Core/Models.swift" "$project_dir/Sources/Core/FeatureConfiguration.swift" "$project_dir"/Sources/Shared/*.swift "$project_dir/Tests/MenuTests.swift" -framework AppKit -o "$project_dir/.build/MenuCraftMenuTests"
"$project_dir/.build/MenuCraftMenuTests"
swiftc -swift-version 5 -parse-as-library "$project_dir"/Sources/Core/*.swift "$project_dir/Tests/ArchiveTests.swift" -framework AppKit -o "$project_dir/.build/MenuCraftArchiveTests"
(cd "$project_dir" && "$project_dir/.build/MenuCraftArchiveTests")
clang -fobjc-arc "$project_dir/Sources/Scroll/MCScrollEngine.m" "$project_dir/Tests/ScrollTests.m" -framework AppKit -framework IOKit -o "$project_dir/.build/MenuCraftScrollTests"
"$project_dir/.build/MenuCraftScrollTests"
swiftc -swift-version 5 -parse-as-library "$project_dir"/Sources/Core/*.swift "$project_dir"/Sources/Runtime/*.swift "$project_dir/Tests/RuntimeTests.swift" -framework AppKit -o "$project_dir/.build/MenuCraftRuntimeTests"
"$project_dir/.build/MenuCraftRuntimeTests"
