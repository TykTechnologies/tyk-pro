# Tyk Automated Testing - Task Commands
# Showcases available task automation commands

Output 04-task-commands.gif
Output 04-task-commands.mp4

Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 20
Set TypingSpeed 50ms

Type "# Tyk Task Automation Commands" Sleep 500ms Enter
Sleep 1s

Type "# List all available tasks" Sleep 500ms Enter
Sleep 500ms
Type "task --list" Sleep 500ms Enter
Sleep 2s

Type "# Login to AWS ECR" Sleep 500ms Enter
Sleep 500ms
Type "task login" Sleep 500ms Enter
Sleep 2s

Type "# Create a local environment" Sleep 500ms Enter
Sleep 500ms
Type "task local FLAVOUR=pro DB=mongo44 VARIATION=murmur64" Sleep 500ms Enter
Sleep 2s

Type "# View environment logs" Sleep 500ms Enter
Sleep 500ms
Type "task logs FLAVOUR=pro DB=mongo44 VARIATION=murmur64" Sleep 500ms Enter
Sleep 2s

Type "# Pull latest images" Sleep 500ms Enter
Sleep 500ms
Type "task pull FLAVOUR=pro DB=mongo44" Sleep 500ms Enter
Sleep 2s

Type "# Clean up environment" Sleep 500ms Enter
Sleep 500ms
Type "task clean FLAVOUR=pro DB=mongo44 VARIATION=murmur64" Sleep 500ms Enter
Sleep 2s

Type "# Task automation makes testing easy!" Sleep 1s Enter
Sleep 2s
