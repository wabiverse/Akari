.PHONY: install bundle run all

# Default target
all: bundle

# Configurable app name (override via command line: make bundle APP_NAME=MyApp)
APP_NAME ?= AkariDemo

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
	SWIFTUSD_BUILD_FROM_SOURCE=1 swift-bundler bundle -c release $(APP_NAME)

run: install
	@echo "▶️  Running $(APP_NAME)..."
	SWIFTUSD_BUILD_FROM_SOURCE=1 swift-bundler run -c release $(APP_NAME)
