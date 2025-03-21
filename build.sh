#!/bin/bash
set -eu

# only for debug
true ${KEEP_CACHE:=1}
true ${EXTERNAL_ROOTFS_DIR:=}

SCRIPTS_DIR=$(cd `dirname $0`; pwd)
if [ -h $0 ]
then
	CMD=$(readlink $0)
	SCRIPTS_DIR=$(dirname $CMD)
fi
cd $SCRIPTS_DIR
cd ../
TOP_DIR=$(pwd)

SDFUSE_DIR=$TOP_DIR/scripts/sd-fuse
# The values of these variables will be overwritten in the.mk file
true ${ENABLE_OVERLAYFS:=true}
true ${ENABLE_OPT_PARTITION:=true}
true ${FRIENDLYWRT_PACKAGE_DIR:=}
declare -a FRIENDLYWRT_FILES=("")
declare -a FRIENDLYWRT_PATCHS=("")

firsttime_usage()
{
	echo ""
	echo "# select board: "
	ALL_MK=`find ./device/friendlyelec -type f -name "*.mk" -printf "%f\n"`
	for mk in ${ALL_MK}; do
		if [ ${mk} != "base.mk" ]; then
			echo "  ./build.sh $mk"
		fi
	done
	ALL_MK_LINK=`find ./device/friendlyelec -type l -name "*.mk" -printf "%f\n"`
		for mk in ${ALL_MK_LINK}; do
			if [ ${mk} != "base.mk" ]; then
				echo "  ./build.sh $mk"
			fi
		done
	echo ""
}

usage()
{
	echo "USAGE: ./build.sh <parameter>"
	firsttime_usage
	echo "# build module: "
	echo "  ./build.sh all                -build all"
	echo "  ./build.sh uboot              -build uboot only"
	echo "  ./build.sh kernel             -build kernel only"
	echo "  ./build.sh friendlywrt        -build friendlywrt rootfs only"
	echo "  ./build.sh sd-img             -pack sd-card image, used to create bootable SD card"
	echo "  ./build.sh emmc-img           -pack sd-card image, used to write friendlywrt to emmc"
	echo "# clean"
	echo "  ./build.sh clean              -remove old images"
	echo "  ./build.sh cleanall"
	echo ""
}

if [ $# -ne 1 ]; then
	usage
	exit 1
fi

function log_error()
{
	local now=`date +%s`
	printf "\033[1;31m[ERROR]: $*\033[0m \n"
}

function log_warn()
{
	local now=`date +%s`
	printf "\033[1;31m[WARN]: $*\033[0m \n"
}

function log_info()
{
	local now=`date +%s`
	printf "\033[1;32m[INFO]: $* \033[0m \n"
}

function build_uboot(){
	# build uboot
	echo "============Start building uboot============"
	echo "SRC				= ${TOP_DIR}/u-boot"
	echo "TARGET_ARCH		= $TARGET_ARCH"
	echo "TARGET_PLAT		= $TARGET_PLAT"
	echo "TARGET_UBOOT_CONFIG=$TARGET_UBOOT_CONFIG"
	echo "TARGET_OSNAME	 = $TARGET_OSNAME"
	echo "========================================="

	(cd ${SDFUSE_DIR} && {
		DISABLE_MKIMG=1 UBOOT_SRC=${TOP_DIR}/u-boot ./build-uboot.sh ${TARGET_OSNAME}
	})

	if [ $? -eq 0 ]; then
		echo "====Building uboot ok!===="
	else
		echo "====Building uboot failed!===="
		exit 1
	fi
}

function build_kernel(){
	# build kernel
	echo "============Start building kernel============"
	echo "SRC				  = ${TOP_DIR}/kernel"
	echo "TARGET_ARCH		  = $TARGET_ARCH"
	echo "TARGET_PLAT		  = $TARGET_PLAT"
	echo "TARGET_KERNEL_CONFIG = $TARGET_KERNEL_CONFIG"
	echo "TARGET_OSNAME		= $TARGET_OSNAME"
	echo "=========================================="

	(cd ${SDFUSE_DIR} && {
		DISABLE_MKIMG=1 KCFG="${TARGET_KERNEL_CONFIG}" KERNEL_SRC=${TOP_DIR}/kernel ./build-kernel.sh ${TARGET_OSNAME}
	})

	if [ $? -eq 0 ]; then
		echo "====Building kernel ok!===="
	else
		echo "====Building kernel failed!===="
		exit 1
	fi
}

function build_friendlywrt(){
	# build friendlywrt
	echo "==========Start build friendlywrt=========="
	echo "TARGET_FRIENDLYWRT_CONFIG=$TARGET_FRIENDLYWRT_CONFIG"
	echo "FRIENDLYWRT_SRC=$FRIENDLYWRT_SRC"
	echo "TARGET_PLAT=$TARGET_PLAT"
	echo "========================================="

	(cd ${FRIENDLYWRT_SRC} && {
		./scripts/feeds update -a && ./scripts/feeds install -a
		if [ $? -ne 0 ]; then
			echo "====Building friendlywrt failed!===="
			exit 1
		fi
	})

	(cd ${TOP_DIR}/${FRIENDLYWRT_SRC} && {
		for (( i=0; i<${#FRIENDLYWRT_PATCHS[@]}; i++ ));
		do
			if [ ! -z ${FRIENDLYWRT_PATCHS[$i]} ]; then
				OLD_IFS="$IFS"
				IFS=";"
				ARR=(${FRIENDLYWRT_PATCHS[$i]})
				IFS="$OLD_IFS"
				if [ ${#ARR[@]} -eq 1 ]; then
					# apply patch to friendlywrt root dir
					log_info "Applying ${FRIENDLYWRT_PATCHS[$i]} to ${FRIENDLYWRT_SRC}"
					git am -3 ${TOP_DIR}/${FRIENDLYWRT_PATCHS[$i]}
				elif [ ${#ARR[@]} -eq 2 ]; then
					# apply patch to sub dir
					if [ -d ${TOP_DIR}/${ARR[1]} ]; then
						(cd ${TOP_DIR}/${ARR[1]} && {
							PATCHS=$(ls)
							cd ${TOP_DIR}/${FRIENDLYWRT_SRC}/${ARR[0]}
							for FILE in ${PATCHS}; do
								log_info "Applying ${FILE} to ${PWD}"
								git am -3 ${TOP_DIR}/${ARR[1]}/${FILE}
							done
						})
					else
						(cd ${ARR[0]} && {
							log_info "Applying ${ARR[1]} to ${FRIENDLYWRT_SRC}/${ARR[0]}"
							git am -3 ${TOP_DIR}/${ARR[1]}
						})
					fi
				else
					echo "failed to apply patch: ${FRIENDLYWRT_PATCHS[$i]}, wrong format, please check it."
				fi
			fi
		done
	})

	true ${DEBUG_DOT_CONFIG:=0}
	/usr/bin/time -f "you take %E to build friendlywrt" $SCRIPTS_DIR/mk-friendlywrt.sh $TARGET_FRIENDLYWRT_CONFIG $FRIENDLYWRT_SRC $TARGET_PLAT
	if [ $? -eq 0 ]; then
		if [ $DEBUG_DOT_CONFIG -eq 0 ]; then
			echo "====Building friendlywrt ok!===="
		fi
	else
		echo "====Building friendlywrt failed!===="
		exit 1
	fi
}

function build_all() {
	build_uboot
	build_kernel
	build_friendlywrt
	build_sdimg
}

function clean_old_images(){
	(cd $TOP_DIR/out && {
		rm -f *.img
		rm -f *.7z
		rm -f *.zip
		rm -rf boot.*
		rm -rf rootfs.*
	})
}

function clean_all(){
	echo "clean uboot, kernel, friendlywrt, img files"
	cd $TOP_DIR/u-boot/ && make distclean && cd -
	cd $TOP_DIR/kernel && make distclean && cd -
	cd $TOP_DIR/friendlywrt && make clean && cd -
	cd ${SDFUSE_DIR} && ./clean.sh && cd -
}

function copy_and_verify(){
	if [ ! -f $1 ]; then
		echo "not found: $1"
		echo "$3"
		exit 1
	fi
	cp $1 $2
}

function prepare_image_for_friendlyelec_eflasher(){
	local OS_DIR=$1
	local ROOTFS=$2
	if [ ! -d ${SDFUSE_DIR}/${OS_DIR} ]; then
		mkdir ${SDFUSE_DIR}/${OS_DIR}
	fi
	rm -rf ${SDFUSE_DIR}/${OS_DIR}/*

	# clean
	rm -rf ${SDFUSE_DIR}/out/boot.*

	local ROOTFS_DIR=${EXTERNAL_ROOTFS_DIR}
	if [ -z $ROOTFS_DIR ]; then
		rm -rf ${SDFUSE_DIR}/out/rootfs.*
		ROOTFS_DIR=$(mktemp -d ${SDFUSE_DIR}/out/rootfs.XXXXXXXXX)
	fi
	log_info "Copying ${TOP_DIR}/${FRIENDLYWRT_SRC}/${FRIENDLYWRT_ROOTFS} to ${ROOTFS_DIR}/"
	cp -af ${TOP_DIR}/${FRIENDLYWRT_SRC}/${FRIENDLYWRT_ROOTFS}/* ${ROOTFS_DIR}/

	echo "$(date +%Y%m%d)" > ${ROOTFS_DIR}/etc/rom-version
	for (( i=0; i<${#FRIENDLYWRT_FILES[@]}; i++ ));
	do
		# apply patch to rootfs
		if [ ! -z ${FRIENDLYWRT_FILES[$i]} ]; then
			log_info "Applying ${FRIENDLYWRT_FILES[$i]} to ${ROOTFS_DIR}"
			if [ -f ${TOP_DIR}/${FRIENDLYWRT_FILES[$i]}/install.sh ]; then
				(cd ${TOP_DIR}/${FRIENDLYWRT_FILES[$i]} && {
					TOP_DIR=${TOP_DIR} ./install.sh ${ROOTFS_DIR}
				})
			else
				rsync -a --no-o --no-g --exclude='.git' ${TOP_DIR}/${FRIENDLYWRT_FILES[$i]}/* ${ROOTFS_DIR}/
			fi
		fi
	done

	# Notes:
	# The following operation must be applied after FRIENDLYWRT_FILES has been applied
	# 
	PKG_DIR=${FRIENDLYWRT_PACKAGE_DIR}
	if [ -z ${PKG_DIR} ]; then
		log_error "pkg_dir is empty, why?"
		exit 1
	else
		[ -d ${ROOTFS_DIR}/usr/local ] || mkdir ${ROOTFS_DIR}/usr/local
		cp -af ${TOP_DIR}/${FRIENDLYWRT_SRC}/${PKG_DIR} ${ROOTFS_DIR}/usr/local
		sed -i -e '/file\:\/\/usr\/local\/$(basename ${PKG_DIR})/d' ${ROOTFS_DIR}/etc/opkg/distfeeds.conf
		echo "src/gz friendlywrt_packages file://usr/local/$(basename ${PKG_DIR})" >> ${ROOTFS_DIR}/etc/opkg/distfeeds.conf
		sed -i '/check_signature/d' ${ROOTFS_DIR}/etc/opkg.conf
	fi

	local BOOT_DIR=$(mktemp -d ${SDFUSE_DIR}/out/boot.XXXXXXXXX)

	# prepare uboot bin, boot.img and rootfs.img
	local UBOOT_DIR=${TOP_DIR}/u-boot
	local KERNEL_DIR=${TOP_DIR}/kernel
	(cd ${SDFUSE_DIR} && {
		./tools/update_uboot_bin.sh ${UBOOT_DIR} ./${OS_DIR}
		if [ $? -ne 0 ]; then
			log_error "error: fail to copy uboot bin file."
			return 1
		fi
		./tools/setup_boot_and_rootfs.sh ${UBOOT_DIR} ${KERNEL_DIR} ${BOOT_DIR} ${ROOTFS_DIR} ./prebuilt ${OS_DIR}
		if [ $? -ne 0 ]; then
			log_error "error: fail to copy kernel to rootfs.img."
			return 1
		fi

		./tools/prepare_friendlywrt_kernelmodules.sh ${ROOTFS_DIR}
		if [ $? -ne 0 ]; then
			log_error "error: fail to fix kernel module for friendlywrt to rootfs.img."
			return 1
		fi

		[ -d ${ROOTFS_DIR}/opt ] || mkdir ${ROOTFS_DIR}/opt
		if [ "${ENABLE_OPT_PARTITION}" = "true" ]; then
			# create a new partition and mount it to the /opt directory
			if [ -f ./tools/make-img.sh ]; then
				log_info "prepare opt.img ..."
				./tools/make-img.sh ${ROOTFS_DIR}/opt opt.img ${OS_DIR}
				if [ $? -eq 0 ]; then
					if [ -f /tmp/make-img-sh-result ]; then
						source /tmp/make-img-sh-result
						if [ -n "${UUID}" ]; then
							rm -rf ${ROOTFS_DIR}/opt/*
							# auto mount partion as /opt
							cat > ${ROOTFS_DIR}/etc/uci-defaults/99-auto-resize-and-mount-opt << EOL
#!/bin/bash
. /lib/functions/uci-defaults.sh

if ! command -v parted >/dev/null || ! command -v resize2fs >/dev/null; then
	logger -t \$0 "Error: 'parted' and/or 'resize2fs' commands are required but not found. Exiting."
	exit 1
fi

UUID="$UUID"
PART=\$(blkid -U "\$UUID")
DISK=\${PART%p*}
PARTNUM=\${PART#\${DISK}p}

if [ ! -b "\${DISK}" ] || [ -z "\${PARTNUM}" ]; then
	logger -t \$0 "Error: Unable to retrieve disk information for UUID '${UUID}'. Exiting."
	exit 1
fi

if command -v sfdisk >/dev/null; then
	if sfdisk -l \${DISK} 2>&1 | grep -q "GPT PMBR size mismatch"; then
		echo "write" | sfdisk \${DISK} -q --force 2>/dev/null
	fi
fi

# resizefs opt partition
parted \$DISK resizepart \$PARTNUM 100%
e2fsck -fy \${PART}
resize2fs -f \${PART}

# refresh partition UUID
if command -v tune2fs >/dev/null; then
	tune2fs -U random \${PART}
	UUID=\$(blkid -o value -s UUID \${PART})
fi

# delete all fstab entries
while uci -q del fstab.@mount[-1]; do true; done

uci add fstab mount
uci set fstab.@mount[-1].target="/opt"
uci set fstab.@mount[-1].uuid="\${UUID}"
uci set fstab.@mount[-1].enabled="1"
uci commit fstab

exit 0
EOL
							chmod 0600 ${ROOTFS_DIR}/etc/uci-defaults/99-auto-resize-and-mount-opt
						else
							echo "error: fail to get uuid."
						fi
					fi
				fi
			else
				ENABLE_OPT_PARTITION=false
				log_warn "warning: no make-img.sh script, skip to create opt.img."
			fi
		fi

		log_info "prepare rootfs.img ..."
		ENABLE_OPT_PARTITION=${ENABLE_OPT_PARTITION} ./build-rootfs-img.sh ${ROOTFS_DIR} ${OS_DIR} \
			$((TARGET_ROOTFS_PARTSIZE * 1024 * 1024)) \
			$((TARGET_USERDATA_PARTSIZE * 1024 * 1024))
		if [ $? -ne 0 ]; then
			log_error "error: fail to gen rootfs.img."
			return 1
		fi

		# no need to generate boot.img for rockchip
		if [ ! -f prebuilt/parameter.template ]; then
			log_info "prepare boot.img ..."
			./build-boot-img.sh ${BOOT_DIR} ./${OS_DIR}/boot.img
			if [ $? -ne 0 ]; then
				log_error "error: fail to gen boot.img."
				return 1
			fi
		fi

		cat > ./${OS_DIR}/info.conf << EOL
title=${OS_DIR}
require-board=${TARGET_PLAT}
version=$(date +%Y-%m-%d)
EOL
		./tools/update_prebuilt.sh ./${OS_DIR} ./prebuilt
		if [ $? -ne 0 ]; then
			log_error "error: fail to copy prebuilt images."
			return 1
		fi

		if [ "${ENABLE_OVERLAYFS}" = "false" -a -f prebuilt/parameter.template ]; then
			# remove userdata from parameter.txt and boot args
			cp -f prebuilt/dtbo-plain.img ${OS_DIR}/dtbo.img
			if [ "${ENABLE_OPT_PARTITION}" = "true" ]; then
				sed -i -E 's/0x[0-9a-fA-F]+@(0x[0-9a-fA-F]+)\(userdata(:grow)?\),-@0x[0-9a-fA-F]+\(opt:grow\)/-@\1(opt:grow)/g' ${OS_DIR}/parameter.txt
			else
				cp -f prebuilt/parameter-plain.txt ${OS_DIR}/parameter.txt
			fi
		fi

		return 0
	})
	if [ $? -ne 0 ]; then
		return 1
	fi

	# clean
	if [ ${KEEP_CACHE} -eq 0 ]; then
		log_info "clean ..."
		rm -rf ${ROOTFS_DIR}
		rm -rf ${BOOT_DIR}
	else
		echo "-----------------------------------------"
		echo "rootfs dir:"
		echo "	${ROOTFS_DIR}"
	echo "boot dir:"
	echo "	${BOOT_DIR}"
		echo "-----------------------------------------"	
	fi
	return 0
}

function clean_device_files()
{
	# create tmp dir
	if [ ! -d ${1}/tmp ]; then
		mkdir ${1}/tmp
	fi
	chmod 1777 ${1}/tmp
	chown root:root ${1}/tmp
	(cd ${1}/dev && find . ! -type d -exec rm {} \;)
}

function build_sdimg(){
	source ${SDFUSE_DIR}/tools/util.sh
	local HAS_BUILT_UBOOT=`has_built_uboot ${TOP_DIR}/u-boot ${SDFUSE_DIR}/out`
	local HAS_BUILD_KERN=`has_built_kernel ${TOP_DIR}/kernel ${SDFUSE_DIR}/out`
	local HAS_BUILD_KERN_MODULES=`has_built_kernel_modules ${TOP_DIR}/kernel ${SDFUSE_DIR}/out`

	# log_info "HAS_BUILT_UBOOT = ${HAS_BUILT_UBOOT}"
	# log_info "HAS_BUILD_KERN = ${HAS_BUILD_KERN}"
	# log_info "HAS_BUILD_KERN_MODULES = ${HAS_BUILD_KERN_MODULES}"

	if [ ${HAS_BUILT_UBOOT} -ne 1 ]; then
		log_error "error: please build u-boot first."
		exit 1
	fi
	
	if [ ${HAS_BUILD_KERN} -ne 1 ]; then
		log_error "error: please build kernel first."
		exit 1
	fi

	if [ ${HAS_BUILD_KERN_MODULES} -ne 1 ]; then
		log_error "error: please build kernel first (miss kernel modules)."
		exit 1
	fi

	local ROOTFS=${TOP_DIR}/${FRIENDLYWRT_SRC}/${FRIENDLYWRT_ROOTFS}
	prepare_image_for_friendlyelec_eflasher ${TARGET_IMAGE_DIRNAME} ${ROOTFS} && (cd ${SDFUSE_DIR} && {
	RAW_SIZE_MB=${TARGET_SD_IMAGESIZE} ./mk-sd-image.sh ${TARGET_IMAGE_DIRNAME} ${TARGET_SD_RAW_FILENAME}
		(cd out && {
		rm -f ${TARGET_SD_RAW_FILENAME}.gz
		gzip --keep ${TARGET_SD_RAW_FILENAME}
	})
		echo "-----------------------------------------"
		echo "Run the following command for sdcard install:"
		echo "	sudo dd if=out/${TARGET_SD_RAW_FILENAME} bs=1M of=/dev/sdX"
		echo "-----------------------------------------"
	})
}

function install_toolchain() {
	if [ ! -d /opt/FriendlyARM/toolchain/4.9.3 ]; then
		log_info "installing toolchain: arm-linux-gcc 4.9.3"
		sudo su -c "mkdir -p /opt/FriendlyARM/toolchain && cat $TOP_DIR/toolchain/gcc-x64/toolchain-4.9.3-armhf.tar.gz* | sudo tar xz -C /"
	fi

	if [ ! -d /opt/FriendlyARM/toolchain/6.4-aarch64 ]; then
		log_info "installing toolchain: aarch-linux-gcc 6.4"
		sudo su -c "mkdir -p /opt/FriendlyARM/toolchain && cat $TOP_DIR/toolchain/gcc-x64/toolchain-6.4-aarch64.tar.gz* | sudo tar xz -C /"
	fi

	if [ ! -d /opt/FriendlyARM/toolchain/11.3-aarch64 ]; then
		log_info "installing toolchain: aarch-linux-gcc 11.3"
		sudo su -c "mkdir -p /opt/FriendlyARM/toolchain && tar xf $TOP_DIR/toolchain/gcc-x64/toolchain-11.3-aarch64.tar.xz -C /"
	fi
}

function build_emmcimg() {
	local ROOTFS=${TOP_DIR}/${FRIENDLYWRT_SRC}/${FRIENDLYWRT_ROOTFS}
	prepare_image_for_friendlyelec_eflasher ${TARGET_IMAGE_DIRNAME} ${ROOTFS} && (cd ${SDFUSE_DIR} && {
		# auto download eflasher image
		if [ ! -f "eflasher/rootfs.img" ]; then
			./tools/get_rom.sh eflasher
		fi
		./mk-emmc-image.sh ${TARGET_IMAGE_DIRNAME} filename=${TARGET_EFLASHER_RAW_FILENAME} autostart=yes
		echo "-----------------------------------------"
		echo "Run the following command for sdcard install:"
		echo "	sudo dd if=out/${TARGET_EFLASHER_RAW_FILENAME} bs=1M of=/dev/sdX"
		echo "-----------------------------------------"
	})
}

##############################################



MK_LINK=".current_config.mk"
FOUND_MK_FILE=`find device/friendlyelec -name ${1} | wc -l`
if [ $FOUND_MK_FILE -gt 0 ]; then
	MK_FILE=`ls device/friendlyelec/*/${1}`
	echo "using config ${MK_FILE}"
	rm -f ${MK_LINK}
	ln -s ${MK_FILE} ${MK_LINK}
	source ${MK_LINK}
	install_toolchain
	build_all
else
	BUILD_TARGET=${1}

	if [ -e "${MK_LINK}" ]; then
		source ${MK_LINK}

		# display var
		# ( set -o posix ; set ) | less
	else
		echo "no .current_config.mk, please select a board first."
		firsttime_usage
		exit 1
	fi
	install_toolchain

	#=========================
	# build target
	#=========================
	if [ $BUILD_TARGET == uboot -o $BUILD_TARGET == u-boot ];then
		build_uboot
		exit 0
	elif [ $BUILD_TARGET == kernel ];then
		build_kernel
		exit 0
	elif [ $BUILD_TARGET == friendlywrt ];then
		build_friendlywrt
		exit 0
	elif [ $BUILD_TARGET == sd-img ]; then
		build_sdimg
		exit 0
	elif [ $BUILD_TARGET == emmc-img ]; then
		build_emmcimg
		exit 0
	elif [ $BUILD_TARGET == all ];then
		build_all
		exit 0
	elif [ $BUILD_TARGET == clean ];then
		clean_old_images
		exit 0
 	elif [ $BUILD_TARGET == cleanall ];then
		# Automatically re-run script under sudo if not root
		if [ $(id -u) -ne 0 ]; then
			echo "Re-running script under sudo..."
			sudo "$0" "$@"
			exit
		fi
		clean_all
		exit 0
	else
		echo "Can't find a build config file, please check again"
		usage
		exit 1
	fi
fi

exit 0
