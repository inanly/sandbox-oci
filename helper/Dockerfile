ARG GO_IMAGE=golang:1.25.4-bookworm
FROM ${GO_IMAGE} AS build
WORKDIR /src
COPY .cache/opensandbox/kubernetes/go.mod .cache/opensandbox/kubernetes/go.sum ./
RUN go mod download
COPY .cache/opensandbox/kubernetes/pkg/imagecommitter ./pkg/imagecommitter
COPY helper/*.go ./cmd/sandbox-oci-helper/
COPY helper/licensecollector/main.go /tools/licensecollector.go
COPY LICENSE NOTICE versions.json /licenses/project/
COPY .cache/opensandbox/LICENSE /licenses/opensandbox/LICENSE
ARG BUILD_TAGS=
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -tags="$BUILD_TAGS" -trimpath -o /helper ./cmd/sandbox-oci-helper
RUN BUILD_TAGS="$BUILD_TAGS" CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go run /tools/licensecollector.go --output /licenses
RUN mkdir -p /licenses/go /licenses/ca-certificates /licenses/toolchain \
    && cp /usr/local/go/LICENSE /usr/local/go/PATENTS /licenses/go/ \
    && cp /usr/share/doc/ca-certificates/copyright /licenses/ca-certificates/copyright \
    && cp -rL /usr/share/common-licenses /licenses/ca-certificates/ \
    && find /usr/local/go/src -type f \( -iname 'LICENSE*' -o -iname 'NOTICE*' -o -iname 'PATENTS*' -o -iname 'COPYING*' \) -exec cp --parents '{}' /licenses/toolchain/ \; \
    && go version -m /helper > /licenses/build-info.txt
FROM scratch
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /helper /helper
COPY --from=build /licenses /usr/share/licenses/sandbox-oci
ENTRYPOINT ["/helper"]
