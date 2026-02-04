# Tyk Automated Testing - Product Showcase

Professional VHS-based video demonstrations for Tyk's automated testing infrastructure.

## Overview

This directory contains automated video generation scripts for creating high-quality product demonstrations, documentation, and training materials using [VHS (Video Handwriting System)](https://github.com/charmbracelet/vhs).

## Directory Structure

```
vhs/
├── Makefile              # Build automation for video generation
├── README.md             # This file
├── configs/              # Shared configuration and themes
│   ├── common.tape       # Common VHS settings
│   └── themes.md         # Theme documentation
├── scripts/              # VHS tape scripts
│   ├── 01-quickstart.tape
│   ├── 02-environment-setup.tape
│   ├── 03-running-tests.tape
│   ├── 04-task-commands.tape
│   ├── 05-cleanup.tape
│   └── 06-advanced-testing.tape
├── outputs/              # Generated media (gitignored)
│   ├── gif/              # GIF outputs
│   └── mp4/              # MP4 video outputs
└── docs/                 # Additional documentation
```

## Prerequisites

### Install VHS

**macOS:**
```bash
brew install vhs
```

**Linux:**
```bash
# Download from releases page
curl -LO https://github.com/charmbracelet/vhs/releases/latest/download/vhs_Linux_x86_64.tar.gz
tar -xzf vhs_Linux_x86_64.tar.gz
sudo mv vhs /usr/local/bin/
```

**Verify installation:**
```bash
vhs --version
```

### Optional Dependencies

For enhanced functionality:
```bash
# Watch mode support
brew install entr

# Additional terminal fonts
brew tap homebrew/cask-fonts
brew install --cask font-jetbrains-mono
```

## Quick Start

### Generate All Demos

```bash
cd vhs
make all
```

This generates both GIF and MP4 versions of all showcase demos.

### Generate Individual Demos

```bash
make quickstart       # Generate quickstart demo only
make setup            # Generate environment setup demo
make testing          # Generate testing demo
make task-commands    # Generate task commands demo
make cleanup          # Generate cleanup demo
make advanced         # Generate advanced testing demo
```

### Clean Generated Files

```bash
make clean
```

## Available Showcases

### 01 - Quick Start
**Duration:** ~30 seconds
**Outputs:** `01-quickstart.{gif,mp4}`

Complete end-to-end workflow demonstrating:
- AWS ECR authentication
- Environment creation with Task
- Container verification
- Test execution
- Environment cleanup

**Use case:** Onboarding new team members

---

### 02 - Environment Setup
**Duration:** ~35 seconds
**Outputs:** `02-environment-setup.{gif,mp4}`

Multi-configuration environment demonstrations:
- Pro vs Pro-HA flavors
- MongoDB vs PostgreSQL databases
- Hash variations (murmur64, sha256)
- Container status monitoring
- Log inspection

**Use case:** Training on environment configurations

---

### 03 - Running Tests
**Duration:** ~40 seconds
**Outputs:** `03-running-tests.{gif,mp4}`

Comprehensive testing workflow:
- Python environment setup
- Authentication configuration
- Test marker usage (gw, dash_api, graphql)
- Targeted test execution
- Directory-based testing

**Use case:** Developer testing documentation

---

### 04 - Task Commands
**Duration:** ~30 seconds
**Outputs:** `04-task-commands.{gif,mp4}`

Task automation demonstration:
- Available task listing
- ECR login automation
- Environment orchestration
- Log management
- Image operations

**Use case:** Task automation reference

---

### 05 - Cleanup
**Duration:** ~25 seconds
**Outputs:** `05-cleanup.{gif,mp4}`

Proper cleanup procedures:
- Environment verification
- Task-based cleanup
- Volume management
- System pruning
- Resource cleanup

**Use case:** Maintenance documentation

---

### 06 - Advanced Testing
**Duration:** ~40 seconds
**Outputs:** `06-advanced-testing.{gif,mp4}`

Advanced testing patterns:
- Pro-HA environment configuration
- Full test suite execution
- Coverage reporting
- Parallel test execution
- Failed test re-running
- HTML report generation

**Use case:** Advanced user training

## Customization

### Using Common Configuration

All scripts use shared configuration from `configs/common.tape`:

```tape
# In your tape script
Source configs/common.tape

Output my-demo.gif
Output my-demo.mp4

# Your demo commands...
```

### Override Settings

Override common settings in individual scripts:

```tape
Source configs/common.tape

# Override specific settings
Set FontSize 18
Set Width 1600

# Your demo commands...
```

### Create New Showcase

1. Create a new tape file in `scripts/`:
```bash
touch scripts/07-my-feature.tape
```

2. Add basic structure:
```tape
# My Feature Demo
Source configs/common.tape

Output 07-my-feature.gif
Output 07-my-feature.mp4

Type "# Demonstrating My Feature" Sleep 500ms Enter
Sleep 1s

# Your commands here...
```

3. Generate:
```bash
make all
```

## CI/CD Integration

See `.github/workflows/vhs-demo.yml` for automated video generation on:
- Pull requests (for preview)
- Releases (for documentation)
- Manual triggers

## Output Formats

### GIF
- **Location:** `outputs/gif/`
- **Best for:** Documentation, READMEs, wikis
- **Pros:** Wide compatibility, inline rendering
- **Cons:** Larger file size

### MP4
- **Location:** `outputs/mp4/`
- **Best for:** Presentations, social media, training
- **Pros:** Smaller size, better quality
- **Cons:** Requires video player

## Best Practices

### Script Design
1. **Keep focused**: One feature per demo
2. **Add context**: Use comments to explain steps
3. **Timing**: Adjust `Sleep` for readability
4. **Test commands**: Verify commands work before recording

### Performance
1. **Batch generation**: Use `make all` for multiple demos
2. **Parallel builds**: Future enhancement for faster generation
3. **Clean regularly**: Remove old outputs with `make clean`

### Maintenance
1. **Version control**: Only commit `.tape` scripts, not outputs
2. **Update regularly**: Keep demos aligned with product changes
3. **Review quality**: Verify outputs before publishing

## Troubleshooting

### VHS Not Found
```bash
make install  # macOS with Homebrew
# Or download manually from VHS releases
```

### Font Issues
```bash
# Install recommended font
brew install --cask font-jetbrains-mono
```

### Output Artifacts
```bash
# Clean stale outputs
make clean

# Regenerate
make all
```

### Timing Issues
Adjust `Sleep` durations in tape scripts:
```tape
Type "command" Sleep 1s Enter  # Increase for slower systems
```

## Contributing

### Adding New Demos

1. Follow naming convention: `##-description.tape`
2. Use sequential numbering
3. Include both GIF and MP4 outputs
4. Add documentation to this README
5. Test generation locally

### Pull Request Checklist

- [ ] Script follows naming convention
- [ ] Uses common configuration
- [ ] Generates both GIF and MP4
- [ ] Documentation updated
- [ ] Successfully tested locally
- [ ] No output files committed

## Resources

- [VHS Documentation](https://github.com/charmbracelet/vhs)
- [VHS Examples](https://github.com/charmbracelet/vhs/tree/main/examples)
- [Tyk Automated Testing](../README.md)
- [Task Automation](../Taskfile.yml)

## License

Copyright © 2026 Tyk Technologies Ltd. All rights reserved.

---

**Generated with VHS** - https://github.com/charmbracelet/vhs
