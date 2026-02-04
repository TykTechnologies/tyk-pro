# Tyk Automated Testing - Advanced Testing Scenarios
# Shows advanced testing patterns and configurations

Output 06-advanced-testing.gif
Output 06-advanced-testing.mp4

Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 20
Set TypingSpeed 50ms

Type "# Advanced Testing Scenarios" Sleep 500ms Enter
Sleep 1s

Type "# Pro-HA environment with full test suite" Sleep 500ms Enter
Sleep 800ms
Type "task local FLAVOUR=pro-ha DB=mongo44 VARIATION=murmur64" Sleep 500ms Enter
Sleep 2s

Type "# Export authentication secret from bootstrap output" Sleep 500ms Enter
Sleep 500ms
Type "export USER_API_SECRET=54321" Sleep 500ms Enter
Sleep 1s

Type "# Run comprehensive test suite excluding local/dind tests" Sleep 500ms Enter
Sleep 500ms
Type "pytest -c pytest_local.ini --ci -m 'not local and not dind' -v" Sleep 500ms Enter
Sleep 3s

Type "# Run tests with coverage report" Sleep 500ms Enter
Sleep 500ms
Type "pytest -c pytest_local.ini --ci --cov=. --cov-report=html" Sleep 500ms Enter
Sleep 2s

Type "# Run tests in parallel for faster execution" Sleep 500ms Enter
Sleep 500ms
Type "pytest -c pytest_local.ini --ci -n auto" Sleep 500ms Enter
Sleep 2s

Type "# Run only failed tests from last run" Sleep 500ms Enter
Sleep 500ms
Type "pytest -c pytest_local.ini --ci --lf" Sleep 500ms Enter
Sleep 2s

Type "# Generate detailed test report" Sleep 500ms Enter
Sleep 500ms
Type "pytest -c pytest_local.ini --ci --html=report.html --self-contained-html" Sleep 500ms Enter
Sleep 2s

Type "# Advanced testing complete!" Sleep 1s Enter
Sleep 2s
