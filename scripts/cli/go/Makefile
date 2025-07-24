# GeoIP Updater Go Build Makefile

# Variables
BINARY_NAME := geoip-update
VERSION := 1.0.0
BUILD_DIR := build
GOFLAGS := -ldflags="-s -w -X main.version=$(VERSION)" -trimpath

# Platforms
PLATFORMS := \
	darwin/amd64 \
	darwin/arm64 \
	linux/amd64 \
	linux/arm64 \
	linux/arm/7 \
	windows/amd64 \
	windows/arm64

# Default target
.PHONY: all
all: clean build

# Build for current platform
.PHONY: build
build:
	@echo "Building for current platform..."
	@go build $(GOFLAGS) -o $(BINARY_NAME) .
	@echo "Built: $(BINARY_NAME)"

# Build for all platforms
.PHONY: build-all
build-all: clean
	@echo "Building for all platforms..."
	@mkdir -p $(BUILD_DIR)
	@for platform in $(PLATFORMS); do \
		GOOS=$$(echo $$platform | cut -d/ -f1) \
		GOARCH=$$(echo $$platform | cut -d/ -f2) \
		GOARM=$$(echo $$platform | cut -d/ -f3) \
		output=$(BUILD_DIR)/$(BINARY_NAME)-$$platform; \
		output=$${output//\//-}; \
		if [ "$$GOOS" = "windows" ]; then output="$$output.exe"; fi; \
		echo "Building $$platform..."; \
		GOOS=$$GOOS GOARCH=$$GOARCH GOARM=$$GOARM go build $(GOFLAGS) -o $$output . || exit 1; \
	done
	@echo "All builds complete!"

# Build with compression (requires upx)
.PHONY: build-compressed
build-compressed: build-all
	@echo "Compressing binaries (requires upx)..."
	@command -v upx >/dev/null 2>&1 || { echo "upx not found. Install with: brew install upx"; exit 1; }
	@for file in $(BUILD_DIR)/*; do \
		echo "Compressing $$(basename $$file)..."; \
		upx --best --lzma "$$file" 2>/dev/null || echo "  Skipped (unsupported format)"; \
	done

# Create release archives
.PHONY: release
release: build-all
	@echo "Creating release archives..."
	@mkdir -p $(BUILD_DIR)/release
	@for platform in $(PLATFORMS); do \
		binary=$(BINARY_NAME)-$$platform; \
		binary=$${binary//\//-}; \
		if [ "$$(echo $$platform | cut -d/ -f1)" = "windows" ]; then \
			binary="$$binary.exe"; \
		fi; \
		archive=$(BUILD_DIR)/release/$(BINARY_NAME)-$(VERSION)-$$platform.tar.gz; \
		archive=$${archive//\//-}; \
		echo "Creating $$(basename $$archive)..."; \
		tar -czf "$$archive" -C $(BUILD_DIR) "$$binary" || exit 1; \
	done
	@echo "Release archives created in $(BUILD_DIR)/release/"

# Install locally
.PHONY: install
install: build
	@echo "Installing to /usr/local/bin..."
	@sudo install -m 755 $(BINARY_NAME) /usr/local/bin/
	@echo "Installed: /usr/local/bin/$(BINARY_NAME)"

# Uninstall
.PHONY: uninstall
uninstall:
	@echo "Uninstalling from /usr/local/bin..."
	@sudo rm -f /usr/local/bin/$(BINARY_NAME)
	@echo "Uninstalled"

# Run tests
.PHONY: test
test:
	@echo "Running tests..."
	@go test -v -race -cover ./...

# Run linters
.PHONY: lint
lint:
	@echo "Running linters..."
	@command -v golangci-lint >/dev/null 2>&1 || { echo "golangci-lint not found. See: https://golangci-lint.run/usage/install/"; exit 1; }
	@golangci-lint run

# Format code
.PHONY: fmt
fmt:
	@echo "Formatting code..."
	@go fmt ./...

# Clean build artifacts
.PHONY: clean
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(BUILD_DIR) $(BINARY_NAME) $(BINARY_NAME).exe
	@echo "Clean complete"

# Show version
.PHONY: version
version:
	@echo "$(VERSION)"

# Development run
.PHONY: run
run:
	@go run . $(ARGS)

# Help
.PHONY: help
help:
	@echo "GeoIP Updater Go Build System"
	@echo ""
	@echo "Targets:"
	@echo "  all            - Clean and build for current platform (default)"
	@echo "  build          - Build for current platform"
	@echo "  build-all      - Build for all supported platforms"
	@echo "  build-compressed - Build and compress with upx"
	@echo "  release        - Create release archives"
	@echo "  install        - Install to /usr/local/bin"
	@echo "  uninstall      - Remove from /usr/local/bin"
	@echo "  test           - Run tests"
	@echo "  lint           - Run linters"
	@echo "  fmt            - Format code"
	@echo "  clean          - Remove build artifacts"
	@echo "  version        - Show version"
	@echo "  run            - Run in development mode"
	@echo "  help           - Show this help"
	@echo ""
	@echo "Examples:"
	@echo "  make                    # Build for current platform"
	@echo "  make build-all         # Build for all platforms"
	@echo "  make release          # Create release archives"
	@echo "  make run ARGS='-help' # Run with arguments"