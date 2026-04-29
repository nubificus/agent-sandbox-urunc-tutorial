FROM golang:1.22 AS builder
WORKDIR /src
COPY ../executor/go.mod .
COPY ../executor/main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /executor .

# Alpine provides busybox (sh) and python3 in a small footprint (~20 MB).
# urunc packages the OCI layers as a block device for Firecracker at pod start.
#
# Requires (copy into this directory before building):
#   vmlinux  — uncompressed kernel ELF (see ../../kernel/README.md)
#   init     — urunc FC init process (extract from any urunc FC image)
FROM alpine:3.20
RUN apk add --no-cache python3
COPY vmlinux /.boot/kernel
COPY init    /init
COPY --from=builder /executor /executor

LABEL com.urunc.unikernel.binary="/.boot/kernel"
LABEL com.urunc.unikernel.hypervisor="firecracker"
LABEL com.urunc.unikernel.unikernelType="linux"
LABEL com.urunc.unikernel.cmdline="/executor"
LABEL com.urunc.unikernel.mountRootfs="true"

CMD ["/init", "/executor"]
