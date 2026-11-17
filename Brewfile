# System tools for building NX2Apple from source: brew bundle --file=Brewfile
# The Mac launcher's setup screen offers the same tools (frontend/Tests/NX2AppleTests/BrewfileTests.swift keeps them equal).
brew "xcodegen"      # generates the Xcode project
brew "zstd"          # decompression
brew "spirv-cross"   # shader translation
brew "glslang"       # glslangValidator: the NSP script checks for it before every build
cask "dotnet-sdk"    # the .NET SDK (10): for the S2Arm engine, and to rebuild nxnative's native extractor and shader translator (dm/tools/native_tools.sh); an nxnative build runs no dotnet
