# VHS Demos Architecture

This document describes the architecture and design decisions for the VHS demo system.

## Overview

The VHS demo system is designed to:
1. Generate consistent, professional product demonstrations
2. Support both GIF and MP4 output formats
3. Enable easy customization and maintenance
4. Integrate with CI/CD for automated generation
5. Provide reusable configuration and themes

## Directory Structure

```
vhs/
├── Makefile                    # Build automation
├── README.md                   # User documentation
├── CHANGELOG.md                # Version history
├── .gitignore                  # Git ignore rules
│
├── configs/                    # Shared configuration
│   ├── common.tape             # Common VHS settings
│   └── themes.md               # Theme documentation
│
├── scripts/                    # VHS tape scripts
│   ├── 01-quickstart.tape
│   ├── 02-environment-setup.tape
│   ├── 03-running-tests.tape
│   ├── 04-task-commands.tape
│   ├── 05-cleanup.tape
│   └── 06-advanced-testing.tape
│
├── outputs/                    # Generated media (gitignored)
│   ├── gif/                    # GIF outputs
│   └── mp4/                    # MP4 video outputs
│
└── docs/                       # Additional documentation
    ├── CONTRIBUTING.md         # Contribution guidelines
    └── ARCHITECTURE.md         # This file
```

## Design Principles

### 1. Separation of Concerns

- **Scripts**: Demo logic and content
- **Configs**: Visual styling and common settings
- **Outputs**: Generated artifacts (not version controlled)
- **Docs**: Documentation and guidelines

### 2. DRY (Don't Repeat Yourself)

- Common settings in `configs/common.tape`
- Shared theme configuration
- Makefile targets for repetitive tasks
- CI/CD workflow for automation

### 3. Convention Over Configuration

- Numbered naming convention: `##-description.tape`
- Standard output formats: GIF and MP4
- Consistent directory structure
- Predictable file locations

### 4. Maintainability

- Clear documentation
- Contributing guidelines
- Version controlled scripts (not outputs)
- Automated validation in CI/CD

## Component Details

### Makefile

**Purpose**: Automate demo generation and management

**Key Targets**:
- `make all`: Generate all demos
- `make quickstart`, `make setup`, etc.: Generate specific demos
- `make clean`: Remove generated outputs
- `make check`: Verify VHS installation
- `make install`: Install VHS (macOS)

**Design**:
- Pattern rules for DRY generation
- Directory creation as prerequisites
- Validation before generation
- Clear help output

### Common Configuration

**File**: `configs/common.tape`

**Purpose**: Provide consistent styling across all demos

**Settings**:
- Terminal dimensions (1400x800)
- Font (JetBrains Mono, 16pt)
- Theme (Dracula)
- Timing defaults
- Animation settings

**Usage**:
```tape
Source configs/common.tape
```

### VHS Scripts

**Location**: `scripts/`

**Naming**: `##-description.tape` (e.g., `01-quickstart.tape`)

**Structure**:
```tape
# Title and description
Source configs/common.tape

# Output declarations
Output ##-description.gif
Output ##-description.mp4

# Demo content
Type "commands..." Sleep XYZms Enter
```

**Guidelines**:
- 20-45 second duration
- Clear, focused content
- Explanatory comments
- Proper timing

### CI/CD Workflow

**File**: `.github/workflows/vhs-demo.yml`

**Triggers**:
- Push to main (changes to VHS files)
- Pull requests (preview)
- Releases (asset upload)
- Manual dispatch (on-demand)

**Jobs**:
1. **generate-demos**: Generate all or specific demos
2. **validate-scripts**: Validate tape file syntax and conventions

**Artifacts**:
- GIF outputs (30-day retention)
- MP4 outputs (30-day retention)
- Release assets (permanent)

## Data Flow

```
┌─────────────────┐
│  Tape Script    │
│  (scripts/)     │
└────────┬────────┘
         │
         ├─ Loads
         │
         ▼
┌─────────────────┐
│ Common Config   │
│ (configs/)      │
└────────┬────────┘
         │
         ├─ Applies
         │
         ▼
┌─────────────────┐
│   VHS Engine    │
│   (generates)   │
└────────┬────────┘
         │
         ├─ Outputs
         │
         ▼
┌─────────────────┐
│  GIF & MP4      │
│  (outputs/)     │
└─────────────────┘
```

## Build Process

### Local Development

1. Edit tape script in `scripts/`
2. Run `make <target>` to generate
3. Review outputs in `outputs/`
4. Iterate as needed
5. Commit only script changes

### CI/CD Pipeline

1. **Trigger**: Push to main or PR
2. **Setup**: Install VHS and dependencies
3. **Validation**: Check script syntax and naming
4. **Generation**: Run VHS on scripts
5. **Upload**: Store artifacts
6. **Release**: Attach to GitHub release (if applicable)

## Configuration Management

### Common Settings

Defined in `configs/common.tape`:
- Terminal size
- Font settings
- Theme colors
- Animation timing
- Playback speed

### Per-Script Overrides

Scripts can override common settings:
```tape
Source configs/common.tape

# Override
Set FontSize 18
Set Width 1600
```

### Theme Customization

Themes defined in `configs/common.tape`:
- Color palette
- Background/foreground colors
- Cursor styling

See `configs/themes.md` for alternatives.

## Output Management

### Gitignore Strategy

**Ignored** (`.gitignore`):
- `outputs/` directory (all generated files)
- `*.gif`, `*.mp4`, `*.webm` (anywhere)
- `.vhs/` (VHS cache)
- Temporary files

**Tracked**:
- Tape scripts (`.tape` files)
- Configuration files
- Documentation
- Makefile and CI/CD configs

### Artifact Storage

**Local Development**:
- Outputs stored in `outputs/{gif,mp4}/`
- Can be cleaned with `make clean`
- Not committed to git

**CI/CD**:
- GitHub Actions artifacts (30 days)
- Release assets (permanent)
- Downloadable from Actions tab or Releases

## Testing Strategy

### Script Validation

**Automated Checks**:
- Output directive presence
- Naming convention compliance
- File syntax validation

**Manual Review**:
- Visual quality
- Timing appropriateness
- Content accuracy
- Professional appearance

### CI/CD Validation

**validate-scripts** job:
- Checks all tape files
- Verifies naming convention
- Ensures Output directives
- Runs on every push/PR

## Extensibility

### Adding New Demos

1. Create `scripts/##-new-demo.tape`
2. Source common config
3. Add demo content
4. Update `vhs/README.md`
5. Generate and test

### Adding New Themes

1. Create theme definition in `configs/`
2. Document in `configs/themes.md`
3. Optional: Add Makefile target
4. Test with existing demos

### Custom Output Formats

VHS supports WebM:
```tape
Output demo.webm
```

Add to Makefile if needed.

## Performance Considerations

### Generation Time

- Single demo: 5-15 seconds
- All demos (6): 30-90 seconds
- Depends on: script length, system resources

### Optimization

1. **Parallel generation**: Future enhancement
2. **Caching**: VHS caches some assets
3. **Batch processing**: `make all` is efficient

### File Size

**GIF**:
- Larger file size (1-5 MB typical)
- Good for inline documentation
- Limited color palette

**MP4**:
- Smaller file size (0.5-2 MB typical)
- Better quality
- Requires video player

## Security Considerations

### Sensitive Data

**Never include**:
- API keys or tokens
- Passwords or credentials
- Internal URLs or IPs
- Customer data

**Use placeholders**:
```tape
Type "export API_KEY=<your-key>" Sleep 500ms Enter
```

### CI/CD Secrets

- Use GitHub Secrets for credentials
- Never log sensitive values
- Validate before public release

## Future Enhancements

### Planned

- [ ] Parallel demo generation
- [ ] Additional themes
- [ ] Interactive demo selector
- [ ] Automated demo updates on product changes
- [ ] Integration with documentation site

### Under Consideration

- [ ] WebM output support
- [ ] Custom resolution templates
- [ ] Demo preview in PR comments (with images)
- [ ] Automated screenshot extraction
- [ ] Multi-language support

## Troubleshooting

### Common Issues

1. **VHS not found**: Run `make install` or install manually
2. **Font rendering**: Install JetBrains Mono
3. **Timing issues**: Adjust `Sleep` values
4. **Output size**: Reduce dimensions or framerate

See `vhs/README.md` for detailed troubleshooting.

## References

- [VHS Documentation](https://github.com/charmbracelet/vhs)
- [Make Manual](https://www.gnu.org/software/make/manual/)
- [GitHub Actions](https://docs.github.com/en/actions)
- [Semantic Versioning](https://semver.org/)

---

**Last Updated**: 2026-02-04
