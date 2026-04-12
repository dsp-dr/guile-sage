# guile-sage Docker image
# Minimal Alpine-based container with Guile 3.0
FROM alpine:3.21 AS builder

# Install build dependencies
RUN apk add --no-cache \
    guile \
    guile-dev \
    guile-readline \
    make \
    curl

# Copy source
WORKDIR /build
COPY . .

# Build compiled objects
RUN make build

# Runtime image
FROM alpine:3.21

# Install runtime dependencies only (readline needed by repl.scm)
RUN apk add --no-cache \
    guile \
    guile-readline \
    curl

# Create sage user
RUN adduser -D -h /home/sage sage

# Copy built artifacts
COPY --from=builder /build/src /opt/sage/src
COPY --from=builder /build/resources /opt/sage/resources

# Set up environment
ENV GUILE_LOAD_PATH=/opt/sage/src
WORKDIR /workspace

# Default to sage user
USER sage

# Entry point
ENTRYPOINT ["guile", "-L", "/opt/sage/src", "-c", "(use-modules (sage main)) (main (command-line))"]
CMD ["--help"]
