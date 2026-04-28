# Build the Go executor
FROM golang:1.22 AS builder
WORKDIR /src
COPY ../executor/go.mod .
COPY ../executor/main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /executor .

# Package the urunc Firecracker image
# Requires:
#   vmlinux   — uncompressed kernel ELF (see ../../kernel/README.md)
#   init      — urunc init process for FC (extract from any FC urunc image, or
#               build from https://github.com/urunc-dev/urunc)
#
# Firecracker does not support virtiofs, so the rootfs is derived from the OCI
# container layers at runtime by urunc (packed into a block device snapshot).
FROM scratch
COPY vmlinux    /.boot/kernel
COPY init       /init
COPY --from=builder /executor /executor

LABEL com.urunc.unikernel.binary="/.boot/kernel"
LABEL com.urunc.unikernel.hypervisor="firecracker"
LABEL com.urunc.unikernel.unikernelType="linux"
LABEL com.urunc.unikernel.cmdline="/executor"
LABEL com.urunc.unikernel.mountRootfs="true"

CMD ["/init", "/executor"]
