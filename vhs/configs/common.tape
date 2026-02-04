# Common VHS Configuration
# Include this file in your tape scripts to maintain consistent styling
#
# Usage: Add the following to the top of your tape file:
# Source configs/common.tape

# Terminal dimensions (16:9 aspect ratio for professional look)
Set Width 1920
Set Height 1080
Set Padding 30

# Font settings (larger for better readability)
Set FontSize 20
Set FontFamily "JetBrains Mono"
Set LetterSpacing 1.2
Set LineHeight 1.4

# Animation settings (slower, smoother, higher quality)
Set TypingSpeed 150ms
Set Framerate 120
Set PlaybackSpeed 1.0

# Shell context for command execution
Set Shell "bash"

# Theme (Pure Black - Maximum contrast)
Set Theme {
  "name": "Pure Black",
  "black": "#000000",
  "red": "#FF6B6B",
  "green": "#4ECB71",
  "yellow": "#FFD93D",
  "blue": "#6BCFFF",
  "magenta": "#C77DFF",
  "cyan": "#00E5FF",
  "white": "#E0E0E0",
  "brightBlack": "#666666",
  "brightRed": "#FF8787",
  "brightGreen": "#6FE895",
  "brightYellow": "#FFE066",
  "brightBlue": "#85D8FF",
  "brightMagenta": "#D99FFF",
  "brightCyan": "#33EEFF",
  "brightWhite": "#FFFFFF",
  "background": "#000000",
  "foreground": "#E0E0E0",
  "selectionBackground": "#333333",
  "cursorColor": "#00E5FF"
}
