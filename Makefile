.PHONY: install bundle run all

# Default target
all: bundle

# Configurable app name (override via command line: make bundle APP_NAME=MyApp)
APP_NAME ?= AkariDemo
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
	SWIFTUSD_BUILD_FROM_SOURCE=1 swift-bundler bundle -c $(BUILD_CONFIG) $(APP_NAME)

run: install
	@echo "▶️  Running $(APP_NAME)..."
	@SWIFTUSD_BUILD_FROM_SOURCE=1 swift-bundler run \
	$(if $(IS_SKIP_TRUE),--skip-build) \
	-c $(BUILD_CONFIG) $(APP_NAME) \
	$(if $(USD_SCENE),-- --usd $(USD_SCENE));
