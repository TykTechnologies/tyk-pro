# S2C - Quick Start Demo
# Generate Go code from OpenAPI specifications

Output "01-quickstart.gif"
Output "01-quickstart.mp4"

Source ../configs/common.tape

Type "clear" Enter
Sleep 500ms
Type "# S2C - Quick Start" Enter
Type "# ==================" Enter
Sleep 3s

# Step 0: Show s2c installation
Type "" Enter
Type "# Check s2c installation" Enter
Sleep 1s
Type "which s2c" Enter
Sleep 2s

Type "" Enter
Type "s2c version" Enter
Sleep 2s

# Step 1: Create modern Train Travel API spec
Type "" Enter
Type "# Step 1: Create modern Train Travel API specification" Enter
Sleep 1.5s
Type "vim openapi.yaml" Enter
Sleep 1.5s

# Enter insert mode and create OpenAPI spec
Type "i"
Sleep 300ms
Type "openapi: 3.1.0" Enter
Type "info:" Enter
Type "  title: Train Travel API" Enter
Type "  version: 1.0.0" Enter
Type "  description: API for booking train trips across Europe" Enter
Type "  x-go-module: github.com/example/train-travel" Enter
Type "  x-go-package: traintravel" Enter
Type "  x-api-category: transportation" Enter
Type "servers:" Enter
Type "  - url: https://api.example.com" Enter
Type "    description: Production" Enter
Type "    x-environment: production" Enter
Type "security:" Enter
Type "  - OAuth2: [read, write]" Enter
Type "paths:" Enter
Type "  /stations:" Enter
Type "    get:" Enter
Type "      operationId: getStations" Enter
Type "      summary: Get train stations" Enter
Type "      x-cache-ttl: 300" Enter
Type "      parameters:" Enter
Type "        - name: limit" Enter
Type "          in: query" Enter
Type "          schema:" Enter
Type "            type: integer" Enter
Type "            default: 20" Enter
Type "          x-go-name: Limit" Enter
Type "      responses:" Enter
Type "        '200':" Enter
Type "          description: List of stations" Enter
Type "  /trips:" Enter
Type "    get:" Enter
Type "      operationId: getTrips" Enter
Type "      summary: Search train trips" Enter
Type "      x-cache-ttl: 60" Enter
Type "      x-rate-limit: 100" Enter
Type "      responses:" Enter
Type "        '200':" Enter
Type "          description: Available trips" Enter
Type "  /bookings:" Enter
Type "    post:" Enter
Type "      operationId: createBooking" Enter
Type "      summary: Create a booking" Enter
Type "      x-requires-auth: true" Enter
Type "      x-rate-limit: 50" Enter
Type "      responses:" Enter
Type "        '201':" Enter
Type "          description: Booking created" Enter
Type "components:" Enter
Type "  securitySchemes:" Enter
Type "    OAuth2:" Enter
Type "      type: oauth2" Enter
Type "      x-token-url: https://auth.example.com/token" Enter
Type "      flows:" Enter
Type "        authorizationCode:" Enter
Type "          authorizationUrl: https://auth.example.com/oauth2/authorize" Enter
Type "          tokenUrl: https://auth.example.com/oauth2/token" Enter
Type "          scopes:" Enter
Type "            read: Read access" Enter
Type "            write: Write access" Enter
Type "x-codegen:" Enter
Type "  go:" Enter
Type "    packageName: traintravel" Enter
Type "    generateInterfaces: true"
Sleep 800ms

# Save and exit
Escape
Sleep 500ms
Type ":wq" Enter
Sleep 1.5s

# Show the spec
Type "" Enter
Type "# Preview the specification" Enter
Sleep 1s
Type "cat openapi.yaml" Enter
Sleep 3s

# Step 2: Generate CLI
Type "" Enter
Type "# Step 2: Generate CLI tool from OpenAPI spec" Enter
Sleep 1.5s
Type "s2c generate --type cli --input openapi.yaml --output ./train-travel-cli" Enter
Sleep 5s

# Step 3: Check generated files
Type "" Enter
Type "# Step 3: Check the generated structure" Enter
Sleep 1.5s
Type "ls -la train-travel-cli/" Enter
Sleep 3s

Type "tree train-travel-cli/ -L 2" Enter
Sleep 3s

# Step 4: Build the CLI
Type "" Enter
Type "# Step 4: Build the CLI tool" Enter
Sleep 1.5s
Type "cd train-travel-cli && make build" Enter
Sleep 5s

# Step 5: Test the CLI
Type "" Enter
Type "# Step 5: Run the generated CLI" Enter
Sleep 1.5s
Type "./train-travel --help" Enter
Sleep 4s

Type "" Enter
Type "./train-travel stations list --help" Enter
Sleep 3s

# Cleanup
Type "" Enter
Type "cd .." Enter
Sleep 1s
Type "rm -rf train-travel-cli openapi.yaml" Enter
Sleep 1s

# Final message
Type "" Enter
Type "# Demo complete! ✓" Enter
Sleep 4s
