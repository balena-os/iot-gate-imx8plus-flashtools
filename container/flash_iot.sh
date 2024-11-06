#!/bin/bash

set -e

WORK_PATH=$(dirname $(readlink -e ${BASH_SOURCE[0]}))
. ${WORK_PATH}/helpers

balena_image_boot_mnt="/tmp/resin-boot"
balena_image_loop_dev=""
work_dir="/usr/src/app/"

# Parse arguments
while [[ $# -gt 0 ]]; do
	arg="$1"
	case $arg in
		-h|--help)
			help
			exit 0
			;;
		-i|--balena-image)
			if [ -z "$2" ]; then
				log ERROR "\"$1\" argument needs a value."
			fi
			balena_image=$2
			shift
			;;
		*)
			echo "Unrecognized option $1."
			help
			exit 1
			;;
	esac
	shift
done

if [ ! -e $balena_image ]; then
	log ERROR "balenaOS image could not be opened!"
fi

cleanup () {
	exit_code=$?
	umount $balena_image_boot_mnt > /dev/null 2>&1 || true
	losetup -d $balena_image_loop_dev > /dev/null 2>&1 || true
	rm -rf $balena_image_boot_mnt
	if [[ $exit_code -eq 0 ]]; then
		log "Cleanup complete"
	fi
	rm -rf $balena_image_boot_mnt || true
}

trap cleanup EXIT SIGHUP SIGINT SIGTERM

# Extract balenaOS imx-boot

if [ -d ${balena_image} ]; then
	log ERROR "Provided path ${balena_image} is a directory or an inexistent file path. This can happen when passing an incorrect path do the flashing script inside docker."
fi
balena_image_loop_dev="$(losetup -fP --show "${balena_image}")"
mkdir -p $balena_image_boot_mnt > /dev/null 2>&1 || true
mount "${balena_image_loop_dev}p1" "$balena_image_boot_mnt"

# Don't wrap it up by double quotes; readlink can't resolve it
imx_boot_bin=$(readlink -e ${balena_image_boot_mnt}/imx-boot*)
if [[ -z ${imx_boot_bin:-""} ]];then
	log ERROR "Failed to extract device bootloader"
else
	mkdir -p ${work_dir} || true
	cp "${imx_boot_bin}" "${work_dir}/"
	imx_boot_bin=$(basename ${imx_boot_bin})
	log "${imx_boot_bin} has been extracted"
fi


# We can't rely on u-boot being flashed on the device already,
# so let's load it prior to flashing it and the balenaOS image
${work_dir}/mfgtools/build/uuu/uuu "${work_dir}/${imx_boot_bin}"

if [[ $? == 0 ]]; then
	log "${imx_boot_bin} has been loaded... Waiting for a couple seconds to allow fastboot to run..."
else
	log ERROR "Failed to load ${imx_boot_bin}"
fi

# 5 seconds are sufficient for u-boot to enter fastboot mode
sleep 5

${work_dir}/mfgtools/build/uuu/uuu -v -b emmc_all "${work_dir}/${imx_boot_bin}" "${balena_image}"

if [[ $? == 0 ]]; then
	log "Finished writing balenaOS image!"
	log "Please remove programming cable from the PC, power off the board and then power it back on."
else
	log ERROR "Failed to write balenaOS"
fi
