#!/bin/sh
# Builds MarketplaceAdBlock.dylib with the Xcode iOS SDK (no Theos needed).
# Pass MPAB_LOG_ALL=1 to log every GraphQL friendly name.
# Optional feature defaults (all read from the environment if set):
#   MPAB_HIDE_SEEN=0|1         hide listings you've already seen (default 1)
#   MPAB_SEEN_ON_IMPRESSION=0|1  1: seen once shown in a feed page, 0: only once opened (default 1)
#   MPAB_MAX_AGE_HOURS=N       hide listings older than N hours, 0 = off (default 168)
#   MPAB_SORT_NEWEST=0|1       sort each feed page newest first (default 1)
#   MPAB_DEFAULT_LOCAL_TAB=0|1 switch to the Local tab when Marketplace opens (default 1)
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=15.0 \
    -dynamiclib -fobjc-arc -O2 -Wall \
    -DMPAB_LOG_ALL="${MPAB_LOG_ALL:-0}" \
    ${MPAB_HIDE_SEEN:+-DMPAB_HIDE_SEEN=$MPAB_HIDE_SEEN} \
    ${MPAB_SEEN_ON_IMPRESSION:+-DMPAB_SEEN_ON_IMPRESSION=$MPAB_SEEN_ON_IMPRESSION} \
    ${MPAB_MAX_AGE_HOURS:+-DMPAB_MAX_AGE_HOURS=$MPAB_MAX_AGE_HOURS} \
    ${MPAB_SORT_NEWEST:+-DMPAB_SORT_NEWEST=$MPAB_SORT_NEWEST} \
    ${MPAB_DEFAULT_LOCAL_TAB:+-DMPAB_DEFAULT_LOCAL_TAB=$MPAB_DEFAULT_LOCAL_TAB} \
    -framework Foundation -framework UIKit \
    -install_name @rpath/MarketplaceAdBlock.dylib \
    -o MarketplaceAdBlock.dylib Tweak.m
codesign -f -s - MarketplaceAdBlock.dylib
echo "Built $(pwd)/MarketplaceAdBlock.dylib"
