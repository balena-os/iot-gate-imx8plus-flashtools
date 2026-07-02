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

imx_boot_bin=$(readlink -e ${balena_image_boot_mnt}/imx-boot*)
if [[ -z ${imx_boot_bin:-""} ]]; then
	log ERROR "Failed to extract device bootloader"
else
	mkdir -p ${work_dir} || true
	cp "${imx_boot_bin}" "${work_dir}/"
	imx_boot_bin=$(basename ${imx_boot_bin})
	log "${imx_boot_bin} has been extracted"
fi

# -d keeps uuu alive as a daemon so it survives the SPL
# reset during DRAM training/re-enumeration.

log "Flashing device: loading ${imx_boot_bin} and writing balenaOS image ..."
uuu_log="$(mktemp)"
${work_dir}/mfgtools/build/uuu/uuu -v -d -b emmc_all "${work_dir}/${imx_boot_bin}" "${balena_image}" > >(tee "${uuu_log}") 2>&1 &
uuu_pid=$!

while kill -0 ${uuu_pid} 2>/dev/null; do
	if grep -A1 "Start Cmd:FB: done" "${uuu_log}" | grep -q "Okay"; then
		sleep 1  # let final log lines flush
		kill -9 ${uuu_pid} 2>/dev/null || true
		break
	fi
	sleep 1
done
wait ${uuu_pid} 2>/dev/null || true

# uuu's daemon process can also exit on its own (e.g. device disconnected,
# transfer failed) without ever reaching "FB: done". Confirm the actual
# success marker is present in the captured log.

flash_ok=0
if grep -A1 "Start Cmd:FB: done" "${uuu_log}" | grep -q "Okay"; then
	flash_ok=1
fi
rm -f "${uuu_log}"

if [[ ${flash_ok} -ne 1 ]]; then
	log ERROR "Failed to flash device - 'FB: done / Okay' was never reached"
fi

log "Finished writing balenaOS image!"
log "Please remove programming cable from the PC, power off the board and then power it back on."
