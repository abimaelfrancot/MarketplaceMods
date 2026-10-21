#!/bin/sh
# Builds MarketplaceAdBlock.dylib with the Xcode iOS SDK (no Theos needed).
# Pass MPAB_LOG_ALL=1 to log every GraphQL friendly name.
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
    -dynamiclib -fobjc-arc -O2 -Wall \
    -DMPAB_LOG_ALL="${MPAB_LOG_ALL:-0}" \
    -framework Foundation \
    -install_name @rpath/MarketplaceAdBlock.dylib \
    -o MarketplaceAdBlock.dylib Tweak.m
codesign -f -s - MarketplaceAdBlock.dylib
echo "Built $(pwd)/MarketplaceAdBlock.dylib"
