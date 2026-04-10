# Use the official Golang image as the build stage
FROM golang:alpine@sha256:2389ebfa5b7f43eeafbd6be0c3700cc46690ef842ad962f6c5bd6be49ed82039 AS builder

# Set the Current Working Directory inside the container
WORKDIR /app

# Copy the source code into the container
COPY . .

# Build the Go app
RUN go build -o webhook .

# Expose port 9003 to the outside world
EXPOSE 9003

# Command to run the executable
CMD ["./webhook"]
