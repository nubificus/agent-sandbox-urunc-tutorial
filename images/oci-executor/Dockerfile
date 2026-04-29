FROM golang:1.22 AS builder
WORKDIR /src
COPY ../executor/go.mod .
COPY ../executor/main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /executor .

# Standard OCI image for runc / gvisor / kata runtimes.
# No kernel or init process needed — the container runtime provides those.
FROM alpine:3.20
RUN apk add --no-cache python3
COPY --from=builder /executor /executor
ENTRYPOINT ["/executor"]
