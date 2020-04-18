#####################################################
# Dockerfile to build the base container.
# This is based on custom debian jessie debootstrap.
#####################################################
FROM jessie:latest
MAINTAINER Tristan Lelong

# Install required packages.
RUN export DEBIAN_FRONTEND=noninteractive && \
	apt-get update && \
	apt-get clean

# Resources
COPY resources/ /
RUN chmod +x /healthcheck.sh /entrypoint.sh

# Run entrypoint
HEALTHCHECK --interval=10m --timeout=30s --retries=2 CMD /healthcheck.sh
ENTRYPOINT [ "/entrypoint.sh" ]
