# VHS Themes

This directory contains theme configurations for VHS demos.

## Available Themes

### Dracula (Default)
Professional dark theme with excellent contrast and readability.
- **File**: `common.tape`
- **Best for**: Technical demonstrations, developer audiences

### Customizing Themes

To use a different theme, modify the `Set Theme` block in `configs/common.tape` or override it in individual tape files.

Popular themes:
- **One Dark**: VSCode-inspired dark theme
- **Nord**: Cool, arctic-inspired color palette
- **Solarized Dark**: Classic, scientifically designed theme
- **Monokai**: Sublime Text classic theme

## Theme Structure

```tape
Set Theme {
  "name": "ThemeName",
  "black": "#000000",
  "red": "#FF0000",
  "green": "#00FF00",
  "yellow": "#FFFF00",
  "blue": "#0000FF",
  "magenta": "#FF00FF",
  "cyan": "#00FFFF",
  "white": "#FFFFFF",
  "background": "#1E1E1E",
  "foreground": "#D4D4D4",
  "cursorColor": "#FFFFFF"
}
```

## Resources

- [VHS Theme Documentation](https://github.com/charmbracelet/vhs#set-theme)
- [Terminal Color Schemes](https://github.com/mbadolato/iTerm2-Color-Schemes)
