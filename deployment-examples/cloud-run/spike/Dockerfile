# Builds the Cloud Run worker pool spike probe.
# Must be linux/amd64: Cloud Run does not support arm64.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd/ ./cmd/
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o /out/spike ./cmd/server

FROM gcr.io/distroless/static-debian12
COPY --from=build /out/spike /spike
# PORT is the declared port Cloud Run knows about; PORT2 tests whether any
# other port is reachable over Direct VPC ingress.
ENV PORT=8080 PORT2=8081
EXPOSE 8080 8081
ENTRYPOINT ["/spike"]
