# Tyk Automated Testing - Running Test Suites
# Shows how to run different test markers and configurations

Output 03-running-tests.gif
Output 03-running-tests.mp4

Set FontSize 16
Set Width 1400
Set Height 800
Set Padding 20
Set TypingSpeed 50ms

Type "# Running Tyk Automated Tests" Sleep 500ms Enter
Sleep 1s

Type "# First, activate the Python environment" Sleep 500ms Enter
Sleep 500ms
Type "cd ci/auto && pipenv shell" Sleep 500ms Enter
Sleep 1s

Type "# Export required secrets (for Pro-HA)" Sleep 500ms Enter
Sleep 500ms
Type "export USER_API_SECRET=<your-secret>" Sleep 500ms Enter
Sleep 1s

Type "# Run all gateway tests" Sleep 500ms Enter
Sleep 500ms
Type "pytest -c pytest_local.ini --ci -m gw -v" Sleep 500ms Enter
Sleep 2s

Type "# Run dashboard API tests" Sleep 500ms Enter
Sleep 500ms
Type "pytest -c pytest_local.ini --ci -m dash_api -v" Sleep 500ms Enter
Sleep 2s

Type "# Run GraphQL tests" Sleep 500ms Enter
Sleep 500ms
Type "pytest -c pytest_local.ini --ci -m graphql -v" Sleep 500ms Enter
Sleep 2s

Type "# Run specific test by name" Sleep 500ms Enter
Sleep 500ms
Type "pytest -c pytest_local.ini --ci -k test_authentication" Sleep 500ms Enter
Sleep 2s

Type "# Run tests for a specific directory" Sleep 500ms Enter
Sleep 500ms
Type "pytest -c pytest_local.ini --ci tests/gateway/" Sleep 500ms Enter
Sleep 2s

Type "# Test execution complete!" Sleep 1s Enter
Sleep 2s
