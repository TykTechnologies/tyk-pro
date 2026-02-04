# Contributing to VHS Demos

Thank you for your interest in improving Tyk's product showcase demos!

## Getting Started

### Prerequisites

1. **Install VHS**:
   ```bash
   brew install vhs  # macOS
   ```

2. **Install recommended fonts**:
   ```bash
   brew tap homebrew/cask-fonts
   brew install --cask font-jetbrains-mono
   ```

3. **Verify installation**:
   ```bash
   cd vhs
   make check
   ```

## Development Workflow

### Creating a New Demo

1. **Choose a sequential number**:
   ```bash
   # Check existing demos
   ls scripts/
   # Next number is 07
   ```

2. **Create the tape file**:
   ```bash
   touch scripts/07-my-feature.tape
   ```

3. **Add the basic structure**:
   ```tape
   # My Feature Demo - Brief description
   Source configs/common.tape

   Output 07-my-feature.gif
   Output 07-my-feature.mp4

   # Start with a title
   Type "# Tyk Feature - My Feature Demo" Sleep 500ms Enter
   Sleep 1s

   # Demonstrate your feature
   Type "command to run" Sleep 500ms Enter
   Sleep 2s

   # Add explanatory comments
   Type "# This demonstrates..." Sleep 500ms Enter
   Sleep 1s

   # End with a summary
   Type "# Demo complete!" Sleep 1s Enter
   Sleep 2s
   ```

4. **Test locally**:
   ```bash
   cd vhs
   make all  # Or make specific target
   ```

5. **Review outputs**:
   ```bash
   open outputs/gif/07-my-feature.gif
   open outputs/mp4/07-my-feature.mp4
   ```

### Modifying Existing Demos

1. **Edit the tape file**:
   ```bash
   vim scripts/02-environment-setup.tape
   ```

2. **Regenerate**:
   ```bash
   make setup  # For specific demo
   # or
   make all    # For all demos
   ```

3. **Review changes**:
   ```bash
   git diff outputs/  # Should be empty (outputs are gitignored)
   git diff scripts/  # Shows your changes
   ```

## Best Practices

### Script Design

1. **Keep it focused**: One feature/workflow per demo
2. **Use comments**: Explain what's happening
3. **Timing matters**: Adjust `Sleep` durations for readability
4. **Test commands**: Verify all commands work before recording

### Common Patterns

#### Starting a demo
```tape
Type "# Tyk Feature - Demo Title" Sleep 500ms Enter
Sleep 1s
```

#### Running commands
```tape
Type "task command ARG=value" Sleep 500ms Enter
Sleep 2s  # Wait for command to complete
```

#### Adding explanations
```tape
Type "# This step performs..." Sleep 500ms Enter
Sleep 800ms
```

#### Ending a demo
```tape
Type "# Demo complete!" Sleep 1s Enter
Sleep 2s
```

### Timing Guidelines

| Action | Recommended Delay |
|--------|-------------------|
| After typing command | 500ms |
| After Enter | 1-3s (depending on command) |
| Between sections | 1s |
| After comments | 500-800ms |
| Final pause | 2s |

### File Size Optimization

1. **Keep demos short**: 20-45 seconds ideal
2. **Minimize output**: Use `--quiet` flags where appropriate
3. **Use appropriate dimensions**: Don't exceed 1400x800

## Configuration

### Using Common Settings

Always source the common configuration:
```tape
Source configs/common.tape
```

This provides:
- Consistent dimensions (1400x800)
- Standard font (JetBrains Mono, 16pt)
- Professional theme (Dracula)
- Proper timing defaults

### Overriding Settings

Override only when necessary:
```tape
Source configs/common.tape

# Override specific settings
Set FontSize 18        # For better readability
Set Height 900         # For more output
Set TypingSpeed 30ms   # Faster typing
```

## Pull Request Checklist

Before submitting a PR:

- [ ] Script follows naming convention (`##-description.tape`)
- [ ] Uses `Source configs/common.tape`
- [ ] Includes both GIF and MP4 outputs
- [ ] Tested locally with `make all`
- [ ] Documentation updated in `vhs/README.md`
- [ ] No output files (gif/mp4) committed
- [ ] Script validated (passes `make check`)
- [ ] Proper timing (not too fast or too slow)
- [ ] Clear and concise content
- [ ] No sensitive information (credentials, tokens)

## Code Review

When reviewing VHS demo PRs:

1. **Verify naming convention**: `##-description.tape`
2. **Check configuration**: Uses `configs/common.tape`
3. **Test locally**: Run `make all` to verify generation
4. **Review timing**: Not too fast or too slow
5. **Check content**: Clear, accurate, professional
6. **Verify outputs**: No outputs committed to git

## Common Issues

### VHS Not Found
```bash
make install  # macOS only
# Or install manually from GitHub releases
```

### Font Issues
```bash
brew install --cask font-jetbrains-mono
```

### Timing Issues

**Too fast:**
```tape
# Increase Sleep durations
Sleep 2s  # instead of Sleep 1s
```

**Too slow:**
```tape
# Decrease Sleep durations
Sleep 500ms  # instead of Sleep 1s

# Or increase typing speed
Set TypingSpeed 30ms  # faster
```

### Output Size Too Large

1. **Reduce dimensions**:
   ```tape
   Set Width 1200   # instead of 1400
   Set Height 700   # instead of 800
   ```

2. **Shorten demo**: Remove unnecessary sections

3. **Reduce framerate**:
   ```tape
   Set Framerate 30  # instead of 60
   ```

## Resources

- [VHS Documentation](https://github.com/charmbracelet/vhs)
- [VHS Examples](https://github.com/charmbracelet/vhs/tree/main/examples)
- [Terminal Color Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)
- [Tyk Automated Testing](../../README.md)

## Questions?

If you have questions or need help:

1. Check the [VHS README](../README.md)
2. Review existing demos in `scripts/`
3. Open an issue with the `vhs` label
4. Ask in the team chat

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
