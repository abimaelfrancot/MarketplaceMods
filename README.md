# MarketplaceAdBlock

This tweak removes ads from Facebook Marketplace on iOS.

Other tweaks remove ads from the main feed. They do not remove ads from Marketplace. This tweak removes ads from these Marketplace pages:

- Home feed
- Search results
- Listing pages ("Related ads")

## Screenshots

| | Before | After |
|---|---|---|
| Search | <img src="screenshots/search-before.webp" width="250"> | <img src="screenshots/search-after.webp" width="250"> |
| Listing | <img src="screenshots/listing-before.webp" width="250"> | <img src="screenshots/listing-after.webp" width="250"> |

## How it works

Marketplace uses React Native. The app gets its data with GraphQL requests through `RCTNetworking`. Each request has a query name.

The tweak changes `-[RCTNetworking handlerForRequest:]`. It does two things:

1. It stops the ads queries. These queries have names such as `MarketplaceHomeFeedAdsQueryRendererQuery` and `MarketplacePDPPersonalizedAdsQuery`.
2. It filters the feed and search responses. It removes each item that has an ad type, such as `MarketplaceFeedAdStory`.

The tweak does not change normal listings.

The tweak uses only the Objective-C runtime. It does not need Substrate or ElleKit.

## Download

Get the dylib from the [latest release](https://github.com/adamsardo/MarketplaceAdBlock/releases/latest).

- `MarketplaceAdBlock.dylib`: Use this file.
- `MarketplaceAdBlock-debug.dylib`: This file also logs all query names and item types. Use it only for troubleshooting.

## Build

You can build the dylib yourself. You must have Xcode with the iOS SDK.

1. Run `./build.sh`.
2. Get `MarketplaceAdBlock.dylib` from this folder.

To log all query names and item types, run `MPAB_LOG_ALL=1 ./build.sh`.

## Install

1. Get a decrypted Facebook IPA. This repository does not include the IPA.
2. Inject `MarketplaceAdBlock.dylib` into the IPA. Use a sideload tool, for example FlareStore.
3. Install the IPA on your device.

## Tested with

- Facebook iOS 584.0.0
- iOS 27.2 beta
- FlareStore, with "Enable ElleKit" set to off

## Troubleshooting

If you see ads after a Facebook update, do these steps:

1. Inject `MarketplaceAdBlock-debug.dylib`, or build with `MPAB_LOG_ALL=1`.
2. Open Console.app on your Mac.
3. Connect your device.
4. Filter on `MPAdBlock`.
5. Open Marketplace.
6. Find the new query names or ad types in the log.
7. Add them to `Tweak.m`.

## Disclaimer

This is a personal project. It is not related to Meta. Use it at your own risk.
