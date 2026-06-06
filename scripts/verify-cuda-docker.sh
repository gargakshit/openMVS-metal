#!/usr/bin/env bash
# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd "${script_dir}/.." && pwd)"

image="${OPENMVS_CUDA_DOCKER_IMAGE:-nvidia/cuda:12.9.1-devel-ubuntu24.04}"
shm_size="${OPENMVS_CUDA_DOCKER_SHM_SIZE:-4g}"
cache_root="${OPENMVS_CUDA_DOCKER_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/openmvs-cuda-vcpkg}"
vcpkg_dir="${OPENMVS_CUDA_DOCKER_VCPKG_DIR:-/opt/vcpkg}"
triplet="${VCPKG_DEFAULT_TRIPLET:-x64-linux-release}"
generator="${OPENMVS_CUDA_GENERATOR:-Ninja}"
build_jobs="${OPENMVS_CUDA_BUILD_JOBS:-2}"
vcpkg_jobs="${OPENMVS_CUDA_VCPKG_JOBS:-${build_jobs}}"
ctest_jobs="${OPENMVS_CUDA_CTEST_JOBS:-1}"
ctest_timeout="${OPENMVS_CUDA_CTEST_TIMEOUT:-1200}"
extra_cmake_args="${OPENMVS_EXTRA_CMAKE_ARGS:--DOpenMVS_BUILD_VIEWER=OFF -DOpenMVS_USE_PYTHON=OFF -DOpenMVS_USE_SIFTGPU=ON -DOpenMVS_USE_CERES=ON}"
evidence_dir="${OPENMVS_CUDA_EVIDENCE_DIR:-${source_dir}/cuda-verification-evidence}"
host_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/openmvs-cuda-host.XXXXXX")"
host_uid="$(id -u)"
host_gid="$(id -g)"

hash_file() {
	local path="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "${path}" | awk '{print $1}'
	else
		shasum -a 256 "${path}" | awk '{print $1}'
	fi
}

write_evidence_manifest() {
	local manifest="${evidence_dir}/evidence-manifest.log"
	local tmp_manifest="${manifest}.tmp"
	{
		printf 'path\tbytes\tsha256\n'
		while IFS= read -r -d '' file_path; do
			local rel_path="${file_path#${evidence_dir}/}"
			local size
			size="$(wc -c < "${file_path}" | tr -d '[:space:]')"
			printf '%s\t%s\t%s\n' "${rel_path}" "${size}" "$(hash_file "${file_path}")"
		done < <(find "${evidence_dir}" -type f ! -name 'evidence-manifest.log' ! -name 'evidence-manifest.log.tmp' -print0 | sort -z)
	} > "${tmp_manifest}"
	mv "${tmp_manifest}" "${manifest}"
}

persist_host_probe() {
	mkdir -p "${evidence_dir}"
	cp -f "${host_probe_dir}"/*.log "${evidence_dir}/" 2>/dev/null || true
	rm -rf "${host_probe_dir}"
	write_evidence_manifest
}
trap persist_host_probe EXIT

require_host_command() {
	local command_name="$1"
	if ! command -v "${command_name}" >/dev/null 2>&1; then
		printf 'required host command is missing: %s\n' "${command_name}" >&2
		exit 1
	fi
}

require_host_command docker
require_host_command nvidia-smi
{
	printf 'nvidia-smi=%s\n\n' "$(command -v nvidia-smi)"
	nvidia-smi
} > "${host_probe_dir}/host-nvidia-smi.log" 2>&1
docker info > "${host_probe_dir}/docker-info.log" 2>&1
docker run --rm --gpus all "${image}" nvidia-smi > "${host_probe_dir}/docker-nvidia-smi.log" 2>&1

mkdir -p "${cache_root}"

docker run --rm \
	--gpus all \
	--ipc=host \
	--shm-size="${shm_size}" \
	-v "${source_dir}:/work" \
	-v "${cache_root}:/vcpkg-cache" \
	-w /work \
	-e "OPENMVS_CUDA_DOCKER_VCPKG_DIR=${vcpkg_dir}" \
	-e "VCPKG_DEFAULT_TRIPLET=${triplet}" \
	-e "OPENMVS_CUDA_GENERATOR=${generator}" \
	-e "OPENMVS_CUDA_BUILD_JOBS=${build_jobs}" \
	-e "OPENMVS_CUDA_VCPKG_JOBS=${vcpkg_jobs}" \
	-e "OPENMVS_CUDA_CTEST_JOBS=${ctest_jobs}" \
	-e "OPENMVS_CUDA_CTEST_TIMEOUT=${ctest_timeout}" \
	-e "OPENMVS_EXTRA_CMAKE_ARGS=${extra_cmake_args}" \
	-e "OPENMVS_CUDA_DOCKER_HOST_UID=${host_uid}" \
	-e "OPENMVS_CUDA_DOCKER_HOST_GID=${host_gid}" \
	"${image}" \
	bash -lc '
set -euo pipefail
restore_owner() {
	if [[ -n "${OPENMVS_CUDA_DOCKER_HOST_UID:-}" && -n "${OPENMVS_CUDA_DOCKER_HOST_GID:-}" ]]; then
		chown -R "${OPENMVS_CUDA_DOCKER_HOST_UID}:${OPENMVS_CUDA_DOCKER_HOST_GID}" \
			/work/build-cuda-vcpkg \
			/work/cuda-verification-evidence \
			2>/dev/null || true
	fi
}
trap restore_owner EXIT
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y \
	autoconf \
	autoconf-archive \
	automake \
	bison \
	build-essential \
	ca-certificates \
	cmake \
	curl \
	git \
	libdbus-1-dev \
	libgl-dev \
	libglu1-mesa-dev \
	libltdl-dev \
	libtool \
	libxcursor-dev \
	libxi-dev \
	libxinerama-dev \
	libxmu-dev \
	libxtst-dev \
	nasm \
	ninja-build \
	pkg-config \
	python3 \
	tar \
	unzip \
	xorg-dev \
	zip

vcpkg_dir="${OPENMVS_CUDA_DOCKER_VCPKG_DIR}"
if [[ ! -x "${vcpkg_dir}/vcpkg" ]]; then
	rm -rf "${vcpkg_dir}"
	git clone https://github.com/microsoft/vcpkg.git "${vcpkg_dir}"
	"${vcpkg_dir}/bootstrap-vcpkg.sh"
fi

export VCPKG_ROOT="${vcpkg_dir}"
export VCPKG_BINARY_SOURCES="clear;files,/vcpkg-cache,readwrite"
/work/scripts/verify-cuda.sh
'
