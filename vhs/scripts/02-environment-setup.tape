# Tyk Automated Testing - Environment Setup
# Demonstrates creating different Tyk environment configurations

Output 02-environment-setup.gif
Output 02-environment-setup.mp4

Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 20
Set TypingSpeed 50ms

Type "# Tyk Environment Setup - Multiple Configurations" Sleep 500ms Enter
Sleep 1s

Type "# Available environment combinations:" Sleep 500ms Enter
Type "# FLAVOUR: pro, pro-ha" Sleep 300ms Enter
Type "# DB: mongo44, postgres15" Sleep 300ms Enter
Type "# VARIATION: murmur64, sha256" Sleep 300ms Enter
Sleep 1s

Type "# Example 1: Pro with MongoDB" Sleep 500ms Enter
Sleep 800ms
Type "task local FLAVOUR=pro DB=mongo44 VARIATION=murmur64" Sleep 500ms Enter
Sleep 2s

Type "# Example 2: Pro-HA with PostgreSQL" Sleep 500ms Enter
Sleep 800ms
Type "task local FLAVOUR=pro-ha DB=postgres15 VARIATION=sha256" Sleep 500ms Enter
Sleep 2s

Type "# Check environment status" Sleep 500ms Enter
Sleep 500ms
Type "docker compose ps" Sleep 500ms Enter
Sleep 2s

Type "# View logs for a specific service" Sleep 500ms Enter
Sleep 500ms
Type "docker compose logs tyk-gateway --tail=20" Sleep 500ms Enter
Sleep 2s

Type "# Environment setup complete!" Sleep 1s Enter
Sleep 2s
