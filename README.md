# bone-machine's custom Android Kernel for the Samsung A52s 5G (Snapdragon 778G - SM7325)

Based from **A528NKSU4GXE1** with backported changes from A73 5G (**A736BXXUAFYE6**)

Linux v5.4.289, built with Clang v19.0 (plus other compilation optimizations)

### Features

- Implemented KSU-Next (**v3.2.0-legacy**) as root solution, with manual hooks
- Supports both AOSP and One UI ROMs (works on Android 16, should work on other versions)
- Added new GPU minimum frequency step, plus reducing voltage a bit for all other steps and idle timeout
- Enabled KSWAPD CPU mask feature (used in A73 5G)
- Switched ZRAM compression algorithm to LZ4KD
- Disabled several kernel debugging tools, flags, and features
- Enabled CONFIG_TMPFS_XATTR for `mountify` KernelSU module mounting compatibility
- Disabled Samsung Knox
- Switchable SELinux policy

And more (check commit log)

# How to build

### Clang
https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/heads/main/clang-r530567.tar.gz

### Export PATH
`export PATH="/{path-to-your-clang-bin-folder}/clang/bin:$PATH"`

### Make defconfig
`make O=$(pwd)/out ARCH=arm64 vendor/a52sxq_kor_single_defconfig`

### Make
```
make -j$(nproc) \
  O=$(pwd)/out \
  ARCH=arm64 \
  CC=clang \
  LLVM=1 \
  LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-none-linux-gnu- \
  KBUILD_BUILD_USER=example \
  KBUILD_BUILD_HOST=kernel \
  CONFIG_SECTION_MISMATCH_WARN_ONLY=y
```

If asked, use these options

`Enable vDSO for 32-bit applications (COMPAT_VDSO)` **y**

`Clang Shadow Call Stack (SHADOW_CALL_STACK)` **y**

`Use virtually mapped shadow call stacks (SHADOW_CALL_STACK_VMAP)`  **y**

`Link-Time Optimization (LTO)` **2**

`Use Clang's Control Flow Integrity (CFI) (CFI_CLANG)` **n** (or **yes** if not integrating KSU-Next root solution)

`Use CFI shadow to speed up cross-module checks (CFI_CLANG_SHADOW)` **y**

`Use CFI in permissive mode (CFI_PERMISSIVE)` **n**

`Use RELR relocation packing (RELR)` **y**

`Use Clang's ThinLTO (EXPERIMENTAL) (THINLTO)` **y**

### Prepare module files
`cd out/`

`mkdir -p modules_for_zip`

`find . -type f -name "*.ko" -exec cp {} modules_for_zip/ \;`

`find modules_for_zip -type f -name "*.ko" -exec llvm-strip --strip-unneeded {} \;`

### Prepare flashable .zip file
[Magiskboot](https://github.com/topjohnwu/Magisk/releases/download/v29.0/Magisk-v29.0.apk)

[avbtool](https://android.googlesource.com/platform/external/avb/+/refs/heads/main/avbtool.py?format=TEXT)

Extract `boot.img` and `vendor_boot.img` from ROM .zip file (or use the ones from `template-zip-file` folder, located at the kernel root directory)

Erase footer from both of them with `avbtool erase_footer --image {file-image}.img` (not necessary if using the ones from `template-zip-file` folder)

### boot.img
`magiskboot unpack boot.img`

Copy `Image` file, replace with `kernel` file

Repack with `magiskboot repack boot.img` and place in flashable .zip file `images` folder, change its name to `boot.img`

### dtbo.img
Place `dtbo.img` from `out/arch/arm64/boot/` in `images` folder of the flashable .zip file

### vendor_boot.img
`magiskboot unpack -h vendor_boot.img`

Replace `dtb` file with `arch/arm64/boot/dts/vendor/qcom/yupik.dtb`, rename to `dtb`

Open header file and replace first line with `SRPUE26A001` (probably not necessary)

`mkdir ramdisk && cd ramdisk`

`cpio -idm < ../ramdisk.cpio`

`sudo chown -R $(whoami):$(whoami) .`

`rm -rf lib/modules/5.4-gki/*`

Place .ko files from `modules_for_zip/` and `modules.alias`, `modules.dep`, `modules.softdep` and `modules.load` in `lib/modules/`, make sure and `modules.dep` entry lines for each module points to `/lib/modules/` and not `/vendor/lib/modules/`

**Note**: You can find `modules.*` files (`modules.alias`, etc.) in the `template-zip-file` folder at the kernel root directory, along with .ko module files, built for the `ksu-next-aosp` branch (though you shouldn't need them if your build was successful, see `modules_for_zip/` steps)

`cp -rf {kernel-source-directory}/firmware/tsp_stm/fts5cu56a_a52sxq* lib/firmware/tsp_stm/` (not necessary if using `vendor_boot.img` from `template-zip-file` folder, since it is already present)

`sudo chown -R root:root .`

`sudo find . -type d -exec chmod 755 '{}' \;`

`sudo find . -type f -exec chmod 644 '{}' \;`

`sudo find .  -print0 | cpio --null -o -H newc --owner root:root > ../ramdisk.cpio`

`cd ..`

`sudo rm -rf ramdisk/`

Repack with `magiskboot repack vendor_boot.img` and place in flashable .zip file `images` folder, rename to `vendor_boot.img`

### Make flashable .zip file
`zip -r -9 {flashable-kernel-zip-file-name}.zip *` and flash it on your recovery environment

### Start-over
`make ARCH=arm64 mrproper CONFIG_KSU_MANUAL_HOOK=y` (for whatever reason, KSU-Next needs that last flag enabled)

`rm -rf out/`

## Update git submodules
`git submodule update --init --recursive`

## Update KSU-Next definitions
```
cd KernelSU-Next
git fetch --tags
git checkout v3.2.0-legacy
cd ..
git add KernelSU-Next
git commit -m "Update KernelSU-Next to v3.2.0-legacy"
```

## KSU-Next and other notes

Use [mountify](https://github.com/backslashxx/mountify) as the primary metamodule

Update GPU drivers with this [KSU module](https://t.me/adrenolabsupport/242/1157)

Use [Zygisk-Next](https://github.com/Dr-TSNG/ZygiskNext), and this version of [LSPosed](https://t.me/LSPosed/311) if needed (check for newer versions on that Telegram group)

For ad-blocking, just use [bindhosts](https://github.com/bindhosts/bindhosts)

# Credits (*)
**salvogiangri** (kernel, UN1CA ROM), **utkustnr/Frax3r** (kernel, update-binary shell script and README.md instructions), **RisenID** (kernel), **saadelasfur** (kernel), **Simon1511** (AOSP related changes), **MySelly** (crDroid's Nothing-Phone-1 kernel), **rifsxd** (KSU-Next), **backslashxx** (Manual hook implementation for KSU-Next), **osm0sis** (Recovery Flashable Zip shell script), **ravindu644** (kernel compilation), **Samsung** (original kernel source code)

<sub>* There are several commits which do not have the original author's name. In most cases, you can find the source for each change inside each commit. In any case, I do not take credit for them.</sub>

# Resources
https://github.com/Mesa-Labs-Archive/android_kernel_samsung_sm7325/

https://github.com/salvogiangri/android_kernel_samsung_sm7325

https://github.com/utkustnr/android_kernel_samsung_sm7325/

https://github.com/RisenID/kernel_samsung_ascendia_sm7325

https://github.com/saadelasfur/android_kernel_samsung_sm7325/

https://github.com/LineageOS/android_kernel_samsung_sm7325

https://github.com/crdroidandroid/android_kernel_nothing_sm7325/

https://github.com/KernelSU-Next/KernelSU-Next

https://github.com/backslashxx/KernelSU/issues/5#event-24583207399

https://github.com/ravindu644/Android-Kernel-Tutorials

https://opensource.samsung.com/uploadList?menuItem=mobile (SM-A736B, SM-A528B, SM-A528N)