# Tyk Automated Testing - VHS Demo Generation
#
# This Makefile provides targets for generating product showcase videos
# using VHS (Video Handwriting System)

.PHONY: help all clean check install quickstart setup testing task-commands cleanup advanced

# Configuration
SCRIPTS_DIR := scripts
OUTPUTS_DIR := outputs
GIF_DIR := $(OUTPUTS_DIR)/gif
MP4_DIR := $(OUTPUTS_DIR)/mp4
CONFIGS_DIR := configs

# VHS scripts
TAPES := $(wildcard $(SCRIPTS_DIR)/*.tape)
GIFS := $(patsubst $(SCRIPTS_DIR)/%.tape,$(GIF_DIR)/%.gif,$(TAPES))
MP4S := $(patsubst $(SCRIPTS_DIR)/%.tape,$(MP4_DIR)/%.mp4,$(TAPES))

# Default target
help:
	@echo "Tyk Automated Testing - VHS Demo Generation"
	@echo ""
	@echo "Available targets:"
	@echo "  make all           - Generate all demo videos and GIFs"
	@echo "  make quickstart    - Generate quickstart demo only"
	@echo "  make setup         - Generate environment setup demo"
	@echo "  make testing       - Generate testing demo"
	@echo "  make task-commands - Generate task commands demo"
	@echo "  make cleanup       - Generate cleanup demo"
	@echo "  make advanced      - Generate advanced testing demo"
	@echo "  make check         - Verify VHS installation"
	@echo "  make clean         - Remove all generated outputs"
	@echo "  make install       - Install VHS (requires Homebrew on macOS)"
	@echo ""
	@echo "Output locations:"
	@echo "  GIFs: $(GIF_DIR)/"
	@echo "  MP4s: $(MP4_DIR)/"

# Check VHS installation
check:
	@command -v vhs >/dev/null 2>&1 || \
		{ echo "Error: VHS is not installed. Run 'make install' or visit https://github.com/charmbracelet/vhs"; exit 1; }
	@echo "✓ VHS is installed"
	@vhs --version

# Install VHS (macOS with Homebrew)
install:
	@echo "Installing VHS..."
	@if command -v brew >/dev/null 2>&1; then \
		brew install vhs; \
	else \
		echo "Error: Homebrew not found. Please install from https://brew.sh"; \
		echo "Or install VHS manually from https://github.com/charmbracelet/vhs/releases"; \
		exit 1; \
	fi

# Create output directories
$(GIF_DIR) $(MP4_DIR):
	@mkdir -p $@

# Generate all demos
all: check $(GIF_DIR) $(MP4_DIR) $(GIFS) $(MP4S)
	@echo ""
	@echo "✓ All demos generated successfully!"
	@echo ""
	@echo "Output files:"
	@ls -lh $(GIF_DIR)/*.gif $(MP4_DIR)/*.mp4 2>/dev/null || true

# Pattern rule for generating GIFs and MP4s from tape files
$(GIF_DIR)/%.gif $(MP4_DIR)/%.mp4: $(SCRIPTS_DIR)/%.tape | $(GIF_DIR) $(MP4_DIR)
	@echo "Generating: $<"
	@cd $(SCRIPTS_DIR) && vhs $(notdir $<)
	@mv $(SCRIPTS_DIR)/$(notdir $*).gif $(GIF_DIR)/ 2>/dev/null || true
	@mv $(SCRIPTS_DIR)/$(notdir $*).mp4 $(MP4_DIR)/ 2>/dev/null || true
	@echo "✓ Generated: $(notdir $*)"

# Individual demo targets
quickstart: check | $(GIF_DIR) $(MP4_DIR)
	@echo "Generating quickstart demo..."
	@cd $(SCRIPTS_DIR) && vhs 01-quickstart.tape
	@mv $(SCRIPTS_DIR)/01-quickstart.{gif,mp4} ../$(OUTPUTS_DIR)/ 2>/dev/null || \
		(mv $(SCRIPTS_DIR)/01-quickstart.gif ../$(GIF_DIR)/ && mv $(SCRIPTS_DIR)/01-quickstart.mp4 ../$(MP4_DIR)/)
	@echo "✓ Quickstart demo generated"

setup: check | $(GIF_DIR) $(MP4_DIR)
	@echo "Generating environment setup demo..."
	@cd $(SCRIPTS_DIR) && vhs 02-environment-setup.tape
	@mv $(SCRIPTS_DIR)/02-environment-setup.gif ../$(GIF_DIR)/
	@mv $(SCRIPTS_DIR)/02-environment-setup.mp4 ../$(MP4_DIR)/
	@echo "✓ Environment setup demo generated"

testing: check | $(GIF_DIR) $(MP4_DIR)
	@echo "Generating testing demo..."
	@cd $(SCRIPTS_DIR) && vhs 03-running-tests.tape
	@mv $(SCRIPTS_DIR)/03-running-tests.gif ../$(GIF_DIR)/
	@mv $(SCRIPTS_DIR)/03-running-tests.mp4 ../$(MP4_DIR)/
	@echo "✓ Testing demo generated"

task-commands: check | $(GIF_DIR) $(MP4_DIR)
	@echo "Generating task commands demo..."
	@cd $(SCRIPTS_DIR) && vhs 04-task-commands.tape
	@mv $(SCRIPTS_DIR)/04-task-commands.gif ../$(GIF_DIR)/
	@mv $(SCRIPTS_DIR)/04-task-commands.mp4 ../$(MP4_DIR)/
	@echo "✓ Task commands demo generated"

cleanup: check | $(GIF_DIR) $(MP4_DIR)
	@echo "Generating cleanup demo..."
	@cd $(SCRIPTS_DIR) && vhs 05-cleanup.tape
	@mv $(SCRIPTS_DIR)/05-cleanup.gif ../$(GIF_DIR)/
	@mv $(SCRIPTS_DIR)/05-cleanup.mp4 ../$(MP4_DIR)/
	@echo "✓ Cleanup demo generated"

advanced: check | $(GIF_DIR) $(MP4_DIR)
	@echo "Generating advanced testing demo..."
	@cd $(SCRIPTS_DIR) && vhs 06-advanced-testing.tape
	@mv $(SCRIPTS_DIR)/06-advanced-testing.gif ../$(GIF_DIR)/
	@mv $(SCRIPTS_DIR)/06-advanced-testing.mp4 ../$(MP4_DIR)/
	@echo "✓ Advanced testing demo generated"

# Clean generated outputs
clean:
	@echo "Cleaning generated outputs..."
	@rm -rf $(OUTPUTS_DIR)
	@rm -f $(SCRIPTS_DIR)/*.gif $(SCRIPTS_DIR)/*.mp4
	@echo "✓ Clean complete"

# Watch mode (requires entr)
watch:
	@command -v entr >/dev/null 2>&1 || \
		{ echo "Error: entr is not installed. Install with: brew install entr"; exit 1; }
	@echo "Watching for changes in $(SCRIPTS_DIR)..."
	@ls $(SCRIPTS_DIR)/*.tape | entr make all
