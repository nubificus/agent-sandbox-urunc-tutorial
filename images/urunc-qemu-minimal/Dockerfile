# Build the Go executor
FROM golang:1.22 AS builder
WORKDIR /src
COPY ../executor/go.mod .
COPY ../executor/main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /executor .

# Package the urunc QEMU image
# Requires:
#   bzImage   — minimal Linux kernel (see ../../kernel/README.md)
#   urunit    — urunc init process (extract from any urunc image, or build from
#               https://github.com/urunc-dev/urunc)
FROM scratch
COPY bzImage   /.boot/kernel
COPY urunit    /urunit
COPY --from=builder /executor /executor

LABEL com.urunc.unikernel.binary="/.boot/kernel"
LABEL com.urunc.unikernel.hypervisor="qemu"
LABEL com.urunc.unikernel.unikernelType="linux"
LABEL com.urunc.unikernel.cmdline="/executor"
LABEL com.urunc.unikernel.mountRootfs="true"

ENTRYPOINT ["/urunit"]
CMD ["/executor"]
