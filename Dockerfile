ARG RT=amd64-ubuntu:focal-run-20221210
FROM balenalib/${RT}

ENV DEBIAN_FRONTEND noninteractive
WORKDIR /usr/src/app/

# Install dependencies
RUN \
    apt-get update && apt-get install -y libusb-1.0-0-dev libbz2-dev libzstd-dev pkg-config cmake libssl-dev g++ zlib1g-dev git usbutils file && \
    git clone https://github.com/nxp-imx/mfgtools.git && cd mfgtools && git checkout 3a5beb69a3b0e8dcb78bd6a8fabd77f2ebe6018f && \
    cmake -S . -B build  && \
    cmake --build build --target all

COPY ./container/flash_iot.sh /usr/src/app/
COPY ./container/helpers /usr/src/app/
COPY ./README.md /usr/src/app/
COPY ./container/imx-boot /usr/src/app/imx-boot
CMD ["sleep", "infinity"]
