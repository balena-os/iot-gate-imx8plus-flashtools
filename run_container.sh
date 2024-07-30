#!/bin/bash

set -e

. ./container/helpers

# Standard container, if dram and image are not passed directly to this script
cmd="docker container run --rm -it --privileged -v /dev/:/dev/ -v ~/images:/data/images uuu-image /bin/bash"

if ! command -v docker > /dev/null
then
	log ERROR "Docker command not found. At least Docker v20 needs to be installed on your Host....."
fi


# Parse arguments
while [[ $# -gt 0 ]]; do
	arg="$1"
	case $arg in
		-h|--help)
			help run_container
			exit 0
			;;
		-i|--balena-image)
			if [ -z "$2" ]; then
				log ERROR "\"$1\" argument needs a value."
			fi
			balena_image=$2
			shift
			;;
		-a|--arch)
			if [ -z "$2" ]; then
				log ERROR "\$1\" argument needs a value."
			fi
			arch=$2
			shift
			;;
		*)
			echo "Unrecognized option $1."
			help run_container
			exit 1
			;;
	esac
	shift
done

# if -i arg is passed, run the flasher script in container directly
if [ ! -z ${balena_image+x} ]; then
	imageName=`basename ${balena_image}`
	cmd="docker container run --rm -it --privileged -v /dev/:/dev/ -v ${balena_image}:/usr/src/app/${imageName} uuu-image /bin/bash ./flash_iot.sh -i /usr/src/app/${imageName}"
	log "Provisioning process will start now."
fi


if [[ ${arch} = "armv7" ]]; then
	log "Will build flash container for armv7..."
	imageTag="--build-arg RT=armv7hf-ubuntu:focal-run-20221215"
elif [[ ${arch} = "aarch64" ]]; then
	log "Will build flash container for aarch64..."
	imageTag="--build-arg RT=aarch64-ubuntu:focal-run-20221215"
fi

# Build Dockerfile, if image does not exist already
docker build -t uuu-image . ${imageTag}

eval $cmd

