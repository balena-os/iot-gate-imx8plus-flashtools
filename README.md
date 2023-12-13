# IOT-GATE-iMX8PLUS flashing tools

The scripts in this directory allow simplified provisioning of balenaOS images for the following device types:

|Device | Balena device name |
|-------|--------------------|
|IOT-GATE-iMX8PLUS 1GB DRAM | Compulab IOT-GATE-iMX8PLUS 1GB-8GB |
|IOT-GATE-iMX8PLUS 2GB DRAM | Compulab IOT-GATE-iMX8PLUS 2GB-4GB |
|IOT-GATE-iMX8PLUS 4GB DRAM | Compulab IOT-GATE-iMX8PLUS 2GB-4GB |
|IOT-GATE-iMX8PLUS 8GB DRAM | Compulab IOT-GATE-iMX8PLUS 1GB-8GB |

## About

These tools run a Docker container to unpack u-boot from the specified balenaOS image and provision both this bootloader and the OS image to
a device connected to your HOST.

## Required software

A Linux-based host with Docker installed is required. The scripts in this directory have been tested on Ubuntu 22.04.

## How to use

Please follow the steps below to enter Recovery mode and perform provisioning of your Compulab IOT-GATE-iMX8PLUS with balenaOS

### Recovery mode

Make sure your IOT-GATE-iMX8 is not powered. Connect the microUSB port labeled 'PROG" from your IOT-GATE-iMX8PLUS to your Host PC.

Apply power to the device. The green LED located on the front of the device should light up. `lsusb` should show a device similar to:

```
$ lsusb | grep NXP
Bus 001 Device 012: ID 1fc9:0146 NXP Semiconductors SE Blank 865 
```

or

```
root@5ea9a9133c3a:/usr/src/app# lsusb | grep NXP
Bus 001 Device 012: ID 1fc9:0146 NXP Semiconductors 
```

Check the RAM size option of your device and ensure you have downloaded and unzipped the balenaOS image which corresponds to your board's DRAM configuration. Based on your device's DRAM, you will further pass either `d1d8` for the 1GB and 8GB configurations, or `d2d4` for the 2GB and 4GB boards. Passing a DRAM configuration that is not in-line with the balenaOS image used or with the device being flashed will
result may result in an un-bootable device. In such cases, the provisioning process will need to be re-started with the correct configuration.

### Provisioning

These scripts offer two options for provisioning the device:

a) Building, running the container and provisioning the device in one step:

```
$ ./run_container.sh -d <d1d8|d2d4> -i /home/<user>/images/<balena-os.img>
```

NOTE: The absolute path to the images needs to be passed to the script. Please replace <user> and <balena-os> with the actual path and image you intend to use.



b) Running the container and triggering provisioning from the container's command line.

First, create a directory named `images` in your home directory:

```
$ mkdir ~/images
```

Place the unzipped balenaOS image inside `~/images/`. This because the directory will be bind-mounted inside the container in `/data/images/`.

Proceed to build and run the container:

```
$ ./run_container.sh
```


Once the container image starts running, you can start provisioning using:

```
root@5ea9a9133c3a:/usr/src/app# ./flash_iot.sh -d d1d8 -i /data/images/<balena-os.img>
```

### Support

If you are having problems using these scripts, please [raise an issue](https://github.com/balena-os/iot-gate-imx8plus-flashtools/issues) on GitHub and the balena.io team will be happy to help.

