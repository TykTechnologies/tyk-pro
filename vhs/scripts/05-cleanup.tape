# Tyk Automated Testing - Environment Cleanup
# Demonstrates proper cleanup procedures

Output 05-cleanup.gif
Output 05-cleanup.mp4

Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 20
Set TypingSpeed 50ms

Type "# Tyk Environment Cleanup" Sleep 500ms Enter
Sleep 1s

Type "# Check running environments" Sleep 500ms Enter
Sleep 500ms
Type "docker ps" Sleep 500ms Enter
Sleep 2s

Type "# Stop and remove environment (must use same params as creation)" Sleep 500ms Enter
Sleep 800ms
Type "task clean FLAVOUR=pro DB=mongo44 VARIATION=murmur64" Sleep 500ms Enter
Sleep 2s

Type "# Verify containers are stopped" Sleep 500ms Enter
Sleep 500ms
Type "docker ps -a" Sleep 500ms Enter
Sleep 1s

Type "# Remove dangling volumes (optional)" Sleep 500ms Enter
Sleep 500ms
Type "docker volume prune -f" Sleep 500ms Enter
Sleep 1s

Type "# Clean up unused images to save space" Sleep 500ms Enter
Sleep 500ms
Type "docker system prune --volumes" Sleep 500ms Enter
Sleep 1s
Type "y" Sleep 200ms Enter
Sleep 2s

Type "# Cleanup complete - ready for next test run!" Sleep 1s Enter
Sleep 2s
