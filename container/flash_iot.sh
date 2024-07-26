#!/bin/bash

set -e

WORK_PATH=$(dirname $(readlink -e ${BASH_SOURCE[0]}))
. ${WORK_PATH}/helpers

balena_image_boot_mnt="/tmp/resin-boot"
balena_image_loop_dev=""
work_dir="/usr/src/app/"
dram_str="-d1d8"

# Parse arguments
while [[ $# -gt 0 ]]; do
	arg="$1"
	case $arg in
		-h|--help)
			help
			exit 0
			;;
		-d|--dram-conf)
			if [ -z "$2" ]; then
				log ERROR "\"$1\" argument needs a value."
			fi
			dram_conf=$2
			shift
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

if [[ $dram_conf = "d2d4" ]]; then
	dram_str=""
	log "Using bootloader compatible with 2GB and 4GB DRAM versions of IOT-GATE-iMX8PLUS"
elif [[ $dram_conf = "d1d8" ]]; then
	log "Using bootloader compatible with 1GB and 8GB DRAM versions of IOT-GATE-iMX8PLUS"
else
	log ERROR "Unknown or unspecified DRAM VERSION!"
fi

if [ ! -e $balena_image ]; then
	log ERROR "balenaOS image could not be opened!"
fi

cleanup () {
	exit_code=$?
	umount $balena_image_boot_mnt > /dev/null 2>&1 || true
	losetup -d $balena_image_loop_dev > /dev/null 2>&1 || true
	losetup -D
	rm -rf $balena_image_boot_mnt
	if [[ $exit_code -eq 0 ]]; then
		log "Cleanup complete"
	fi
	rm -rf $balena_image_boot_mnt || true
}

trap cleanup EXIT SIGHUP SIGINT SIGTERM

imx_boot_bin="imx-boot-iot-gate-imx8plus${dram_str}-sd.bin-flash_evk"

# Extract balenaOS imx-boot

if [ -d ${balena_image} ]; then
	log ERROR "Provided path ${balena_image} is a directory or an inexistent file path. This can happen when passing an incorrect path do the flashing script inside docker."
fi
balena_image_loop_dev="$(losetup -fP --show "${balena_image}")"
mkdir -p $balena_image_boot_mnt > /dev/null 2>&1 || true
mount "${balena_image_loop_dev}p1" "$balena_image_boot_mnt"

os_major_version=$(cat "${balena_image_boot_mnt}/os-release" | grep -Po '^VERSION="\K[^."]*')
log "OS release major version is $os_major_version"

# Versions older than 5 had to enter fastboot manually
# from u-boot cmdline.
if [[ $os_major_version -le 4 ]]; then
	cp "${work_dir}/imx-boot/${imx_boot_bin}" "${work_dir}/${imx_boot_bin}"
	log "Using local imx-boot ${imx_boot_bin}"
else
	cp "${balena_image_boot_mnt}/${imx_boot_bin}" "${work_dir}/${imx_boot_bin}"
	if [[ $? == 0 ]]; then
		log "${imx_boot_bin} has been extracted"
	else
		log ERROR "Failed to extract ${imx_boot_bin}"
	fi
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
