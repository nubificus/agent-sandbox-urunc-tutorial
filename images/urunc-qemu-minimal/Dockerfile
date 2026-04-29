FROM golang:1.22 AS builder
WORKDIR /src
COPY ../executor/go.mod .
COPY ../executor/main.go .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /executor .

# Alpine provides busybox (sh) and python3 in a small footprint (~20 MB).
# urunc mounts these OCI layers into the VM via virtiofs at boot.
#
# Requires (copy into this directory before building):
#   bzImage  — minimal Linux kernel (see ../../kernel/README.md)
#   urunit   — urunc init process (extract from any urunc QEMU image)
FROM alpine:3.20
RUN apk add --no-cache python3
COPY bzImage /.boot/kernel
COPY urunit  /urunit
COPY --from=builder /executor /executor

LABEL com.urunc.unikernel.binary="/.boot/kernel"
LABEL com.urunc.unikernel.hypervisor="qemu"
LABEL com.urunc.unikernel.unikernelType="linux"
LABEL com.urunc.unikernel.cmdline="/executor"
LABEL com.urunc.unikernel.mountRootfs="true"

ENTRYPOINT ["/urunit"]
CMD ["/executor"]
