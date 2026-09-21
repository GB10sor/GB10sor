{ lib
, stdenv
, fetchurl
, autoreconfHook
, pkg-config
, rdma-core
, numactl
, pciutils
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "perftest";
  version = "26.04.17";

  src = fetchurl {
    url = "https://github.com/linux-rdma/perftest/archive/refs/tags/${finalAttrs.version}.tar.gz";
    hash = "sha256-GERvA5DbsJfmI6tfEAuhY95oZ7xa1OQmaXAePKPEpL8=";
  };

  nativeBuildInputs = [ autoreconfHook pkg-config ];
  buildInputs = [ rdma-core numactl pciutils ];

  # The direct-link qualification uses host-memory ib_write_bw. Avoid
  # accidentally changing the build when a CUDA toolkit happens to be visible.
  configureFlags = [ "--disable-cudart" ];

  meta = {
    description = "InfiniBand Verbs Performance Tests";
    homepage = "https://github.com/linux-rdma/perftest";
    license = lib.licenses.gpl2Only;
    platforms = lib.platforms.linux;
    mainProgram = "ib_write_bw";
  };
})
