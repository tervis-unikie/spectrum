{ lib, stdenv, host-rootfs, extfs, runCommand, runCommandCC
, writeReferencesToFile, pkgsStatic
, busybox, cpio, cryptsetup, dosfstools, jq, linux, lvm2, mtools, systemd
, util-linux
}:

let
  cryptsetup' = cryptsetup;
in
let
  inherit (lib) cleanSource cleanSourceWith concatMapStringsSep;

  cryptsetup = cryptsetup'.override { lvm2 = lvm2.override { udev = null; }; };

  kernelTarget = stdenv.hostPlatform.linux-kernel.target;

  packages = [
    cryptsetup (busybox.override { enableStatic = true; }) pkgsStatic.mdevd
    pkgsStatic.execline
  ];

  packagesSysroot = runCommand "packages-sysroot" {} ''
    mkdir -p $out/bin
    ln -s ${concatMapStringsSep " " (p: "${p}/bin/*") packages} $out/bin
    cp -R ${linux}/lib $out
    ln -s /bin $out/sbin

    # TODO: this is a hack and we should just build the util-linux
    # programs we want.
    # https://lore.kernel.org/util-linux/87zgrl6ufb.fsf@alyssa.is/
    cp ${pkgsStatic.util-linux.override { systemd = null; }}/bin/lsblk $out/bin
  '';

  packagesCpio = runCommand "packages.cpio" {
    nativeBuildInputs = [ cpio ];
    storePaths = writeReferencesToFile packagesSysroot;
  } ''
    cd ${packagesSysroot}
    (printf "/nix\n/nix/store\n" && find . $(< $storePaths)) |
        cpio -o -H newc -R +0:+0 --reproducible > $out
  '';

  initramfs = stdenv.mkDerivation {
    name = "initramfs";

    src = cleanSourceWith {
      filter = name: _type: name != "${toString ./.}/build" && name != "${toString ./.}/spectrum-live";
      src = cleanSource ./.;
    };

    PACKAGES_CPIO = packagesCpio;

    nativeBuildInputs = [ cpio ];

    installPhase = ''
      cp build/initramfs $out
    '';

    enableParallelBuilding = true;
  };

  uki = runCommandCC "spectrum-uki" {
    passAsFile = [ "cmdline" ];
    cmdline = "ro console=ttyS0";
    inherit initramfs;
  } ''
    roothash="$(awk -F ':[[:blank:]]*' '$1 == "Root hash" {print $2; exit}' ${verity.table})"
    echo "ro console=ttyS0 roothash=$roothash" > cmdline
    objcopy --add-section .osrel=${etc/os-release} --change-section-vma .osrel=0x20000 \
            --add-section .cmdline=cmdline --change-section-vma .cmdline=0x30000 \
            --add-section .linux=${linux}/${kernelTarget} --change-section-vma .linux=0x40000 \
            --add-section .initrd=$initramfs --change-section-vma .initrd=0x3000000 \
            ${systemd}/lib/systemd/boot/efi/linuxx64.efi.stub $out
  '';

  efi = runCommand "spectrum-efi" {
    nativeBuildInputs = [ dosfstools mtools ];
    passthru = { inherit uki; };
  } ''
    truncate -s ${toString (100 * 1024 * 1024)} $out
    mkfs.vfat $out
    mmd -i $out ::/EFI ::/EFI/BOOT
    mcopy -i $out ${uki} ::/EFI/BOOT/BOOTX64.EFI
  '';

  verity = runCommand "spectrum-verity" {
    nativeBuildInputs = [ cryptsetup ];
    outputs = [ "out" "table" ];
  } ''
    veritysetup format ${host-rootfs} $out > $table
  '';
in

runCommand "spectrum-live" {
  nativeBuildInputs = [ jq util-linux ];
  passthru = {
    inherit efi verity;
    rootfs = host-rootfs;
  };
} ''
  blockSize() {
      wc -c "$1" | awk '{printf "%d\n", ($1 + 511) / 512}'
  }

  fillPartition() {
      read start size < <(sfdisk -J "$1" | jq -r --argjson index "$2" \
          '.partitiontable.partitions[$index] | "\(.start) \(.size)"')
      dd if="$3" of="$1" seek="$start" count="$size" conv=notrunc
  }

  efiSize="$(blockSize ${efi})"
  veritySize="$(blockSize ${verity})"
  rootfsSize="$(blockSize ${host-rootfs})"
  extSize="$(blockSize ${extfs})"

  truncate -s $(((4 * 2048 + $efiSize + $veritySize + $rootfsSize + $extSize) * 512)) $out
  sfdisk $out <<EOF
  label: gpt
  - $efiSize    U                                    -
  - $veritySize 2c7357ed-ebd2-46d9-aec1-23d437ec2bf5 -
  - $rootfsSize 4f68bce3-e8cd-4db1-96e7-fbcaf984b709 -
  - $extSize    9293e1ff-cee4-4658-88be-898ec863944f -
  EOF

  fillPartition $out 0 ${efi}
  fillPartition $out 1 ${verity}
  fillPartition $out 2 ${host-rootfs}
  fillPartition $out 3 ${extfs}
''
