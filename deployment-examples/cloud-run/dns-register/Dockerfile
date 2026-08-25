# Sidecar that publishes the instance's private IP into Cloud DNS.
# Alpine + curl + jq (~15MB) rather than google/cloud-sdk:slim (~1GB), which
# is disproportionate beside a 30MB nativelink container and made the image
# push fail on a slow link.
FROM alpine:3.20
RUN apk add --no-cache curl jq ca-certificates
COPY register.sh /register.sh
RUN chmod +x /register.sh
ENTRYPOINT ["/register.sh"]
