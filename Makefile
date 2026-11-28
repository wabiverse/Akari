.PHONY: install bundle run signer all dmg testflight

# Default target
all: bundle

# Configurable app name (override via command line: make bundle APP_NAME=MyApp)
APP_NAME ?= Kraken
# Device ID to build or run for (swift-bundler devices list)
PLATFORM ?=
# Device ID to build or run for (swift-bundler devices list)
DEVICE_ID ?=
CODESIGN_IDENTITY ?=
# a development profile for the device, made in the developer portal, else swift-bundler makes one through xcode
IOS_DEV_PROFILE ?=
# device builds claim the larger memory limit and address space, Kraken.entitlements, which the profile has to grant
DEVICE_SIGNING = $(if $(and $(CODESIGN_IDENTITY),$(filter iOS,$(PLATFORM))),--entitlements Kraken.entitlements $(if $(IOS_DEV_PROFILE),--provisioning-profile $(IOS_DEV_PROFILE)))
# Build configuration to use (override via command line: make bundle BUILD_CONFIG=debug)
BUILD_CONFIG ?= release
# USD scene for akari to render (override via command line: make run USD_SCENE=/path/to/scene.usd)
USD_SCENE ?=
# Whether to skip building entirely, and just run Akari (override via command line: make run SKIP_BUILD=1)
SKIP_BUILD ?=0

IS_SKIP_TRUE = $(filter-out 0,$(SKIP_BUILD))

install:
	@if ! command -v swift-bundler >/dev/null 2>&1; then \
		echo "🍺 Installing mint via Homebrew..."; \
		brew install mint; \
		echo "🍺 Installing xcbeautify via Homebrew..."; \
		brew install xcbeautify; \
		echo "📦 Installing swift-bundler via Mint..."; \
		mint install moreSwift/swift-bundler@main; \
	else \
		echo "✅ swift-bundler is already available. Skipping installation."; \
	fi

bundle: install
	@echo "📦 Bundling $(APP_NAME)..."
	SWIFT_COLLECTIVE_DYNAMIC_LIBRARIES=1 SWIFTUSD_BUILD_FROM_SOURCE=1 swift package update
	SWIFT_COLLECTIVE_DYNAMIC_LIBRARIES=1 SWIFTUSD_BUILD_FROM_SOURCE=1 swift-bundler bundle -c $(BUILD_CONFIG) $(if $(PLATFORM),-p $(PLATFORM)) $(if $(DEVICE_ID),--device $(DEVICE_ID)) $(if $(CODESIGN_IDENTITY),--identity $(CODESIGN_IDENTITY) --codesign) $(DEVICE_SIGNING) $(APP_NAME)

run: install
	@echo "▶️  Running $(APP_NAME)..."
	@if [ "$(PLATFORM)" = "iOS" ]; then \
		SWIFT_COLLECTIVE_DYNAMIC_LIBRARIES=1 SWIFTUSD_BUILD_FROM_SOURCE=1 swift package update; \
		SWIFT_COLLECTIVE_DYNAMIC_LIBRARIES=1 SWIFTUSD_BUILD_FROM_SOURCE=1 swift-bundler run $(if $(IS_SKIP_TRUE),--skip-build) -c $(BUILD_CONFIG) $(if $(PLATFORM),-p $(PLATFORM)) $(if $(DEVICE_ID),--device $(DEVICE_ID)) $(if $(CODESIGN_IDENTITY),--identity $(CODESIGN_IDENTITY) --codesign) $(DEVICE_SIGNING) $(APP_NAME); \
	else \
		SWIFT_COLLECTIVE_DYNAMIC_LIBRARIES=1 SWIFTUSD_BUILD_FROM_SOURCE=1 swift package update; \
		SWIFT_COLLECTIVE_DYNAMIC_LIBRARIES=1 SWIFTUSD_BUILD_FROM_SOURCE=1 swift-bundler run $(if $(IS_SKIP_TRUE),--skip-build) -c $(BUILD_CONFIG) $(APP_NAME) $(if $(USD_SCENE),-- --usd $(USD_SCENE)); \
	fi

# Distribution builds, the one time certificate and account setup is at the top of each script.
# a notarized dmg for macOS: make dmg
# a TestFlight upload for iOS: make testflight IOS_PROFILE=~/Downloads/Kraken_AppStore.mobileprovision
DIST_DIR ?= .build/dist
MAC_IDENTITY ?= Developer ID Application
NOTARY_PROFILE ?= kraken-notary
IOS_IDENTITY ?= Apple Distribution
IOS_PROFILE ?=
BUILD_NUMBER ?= $(shell date +%Y%m%d%H%M)

dmg: install
	SWIFT_COLLECTIVE_DYNAMIC_LIBRARIES=1 SWIFTUSD_BUILD_FROM_SOURCE=1 swift package update
	SWIFT_COLLECTIVE_DYNAMIC_LIBRARIES=1 SWIFTUSD_BUILD_FROM_SOURCE=1 swift-bundler bundle -c $(BUILD_CONFIG) $(APP_NAME)
	Tools/Distribute/macos-dmg.sh .build/bundler/apps/$(APP_NAME)/$(APP_NAME).app $(DIST_DIR) "$(MAC_IDENTITY)" $(NOTARY_PROFILE)

testflight: install
	@if [ -z "$(IOS_PROFILE)" ]; then echo "set IOS_PROFILE to the App Store provisioning profile, see Tools/Distribute/ios-testflight.sh"; exit 1; fi
	SWIFT_COLLECTIVE_DYNAMIC_LIBRARIES=1 SWIFTUSD_BUILD_FROM_SOURCE=1 swift package update
	APP_NAME=$(APP_NAME) BUILD_CONFIG=$(BUILD_CONFIG) Tools/Distribute/ios-testflight.sh $(IOS_PROFILE) $(DIST_DIR) "$(IOS_IDENTITY)" $(BUILD_NUMBER)

# The shader signer for hot reload, Tools/ShaderSign/.build/release/akari-sign once built
signer:
	swift build -c release --package-path Tools/ShaderSign
