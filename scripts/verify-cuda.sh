#!/usr/bin/env bash
# Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
# Codex sign-off: OpenAI Codex assisted with this file.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_dir="$(cd "${script_dir}/.." && pwd)"
build_dir="${OPENMVS_CUDA_BUILD_DIR:-${source_dir}/build-cuda-vcpkg}"
build_type="${OPENMVS_CUDA_BUILD_TYPE:-Release}"
build_jobs="${OPENMVS_CUDA_BUILD_JOBS:-2}"
vcpkg_jobs="${OPENMVS_CUDA_VCPKG_JOBS:-${build_jobs}}"
ctest_jobs="${OPENMVS_CUDA_CTEST_JOBS:-1}"
ctest_timeout="${OPENMVS_CUDA_CTEST_TIMEOUT:-1200}"
evidence_dir="${OPENMVS_CUDA_EVIDENCE_DIR:-${source_dir}/cuda-verification-evidence}"
effective_vcpkg_max_concurrency="${VCPKG_MAX_CONCURRENCY:-${vcpkg_jobs}}"

require_file_contains() {
	local path="$1"
	local needle="$2"
	if [[ ! -f "${path}" ]]; then
		printf 'required file is missing: %s\n' "${path}" >&2
		exit 1
	fi
	if ! grep -Fq "${needle}" "${path}"; then
		printf 'required marker is missing from %s: %s\n' "${path}" "${needle}" >&2
		exit 1
	fi
}

require_vcpkg_status_feature() {
	local path="$1"
	local package="$2"
	local feature="$3"
	if [[ ! -f "${path}" ]]; then
		printf 'required vcpkg status file is missing: %s\n' "${path}" >&2
		exit 1
	fi
	if ! awk -v package="${package}" -v feature="${feature}" '
		BEGIN { RS = ""; FS = "\n"; found = 0 }
		{
			has_package = 0
			has_feature = (feature == "core")
			has_status = 0
			for (i = 1; i <= NF; ++i) {
				if ($i == "Package: " package)
					has_package = 1
				if ($i == "Feature: " feature)
					has_feature = 1
				if ($i == "Status: install ok installed")
					has_status = 1
			}
			if (has_package && has_feature && has_status)
				found = 1
		}
		END { exit found ? 0 : 1 }
	' "${path}"; then
		printf 'required vcpkg package feature is missing from %s: %s[%s]\n' "${path}" "${package}" "${feature}" >&2
		exit 1
	fi
}

run_self_test() {
	local tmp_dir
	tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/openmvs-cuda-self-test.XXXXXX")"
	trap 'rm -rf "${tmp_dir}"' RETURN
	local good_status="${tmp_dir}/status-good"
	local missing_status="${tmp_dir}/status-missing"
	cat > "${good_status}" <<'STATUS'
Package: cuda
Version: 12.9
Architecture: x64-linux-release
Status: install ok installed

Package: ceres
Feature: cuda
Architecture: x64-linux-release
Status: install ok installed

Package: siftgpu
Feature: cuda
Architecture: x64-linux-release
Status: install ok installed
STATUS
	cat > "${missing_status}" <<'STATUS'
Package: cuda
Version: 12.9
Architecture: x64-linux-release
Status: install ok installed

Package: ceres
Feature: cuda
Architecture: x64-linux-release
Status: install ok installed

Package: siftgpu
Feature: core
Architecture: x64-linux-release
Status: install ok installed
STATUS
	require_vcpkg_status_feature "${good_status}" cuda core
	require_vcpkg_status_feature "${good_status}" ceres cuda
	require_vcpkg_status_feature "${good_status}" siftgpu cuda
	if (require_vcpkg_status_feature "${missing_status}" siftgpu cuda) 2>/dev/null; then
		printf 'self-test expected missing siftgpu[cuda] to fail\n' >&2
		exit 1
	fi
	printf 'CUDA verifier self-test passed\n'
}

if [[ "${OPENMVS_CUDA_SELF_TEST:-}" == "1" ]]; then
	run_self_test
	exit 0
fi

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

finalize_evidence() {
	local status="$1"
	{
		printf 'exit_status=%s\n' "${status}"
		if [[ "${status}" == "0" ]]; then
			printf 'result=success\n'
		else
			printf 'result=failure\n'
		fi
	} > "${evidence_dir}/verification-result.log" || true
	write_evidence_manifest || true
}

rm -rf "${evidence_dir}"
mkdir -p "${evidence_dir}"
trap 'finalize_evidence "$?"' EXIT

{
	printf 'source_dir=%s\n' "${source_dir}"
	printf 'build_dir=%s\n' "${build_dir}"
	printf 'build_type=%s\n' "${build_type}"
	printf 'build_jobs=%s\n' "${build_jobs}"
	printf 'vcpkg_jobs=%s\n' "${vcpkg_jobs}"
	printf 'ctest_jobs=%s\n' "${ctest_jobs}"
	printf 'ctest_timeout=%s\n' "${ctest_timeout}"
	printf 'VCPKG_MAX_CONCURRENCY=%s\n' "${effective_vcpkg_max_concurrency}"
} > "${evidence_dir}/verification-environment.log"

if ! command -v nvidia-smi >/dev/null 2>&1; then
	printf 'nvidia-smi is required for CUDA verification hardware evidence\n' | tee "${evidence_dir}/nvidia-smi.log" >&2
	exit 1
fi
if ! command -v git >/dev/null 2>&1; then
	printf 'git is required for CUDA verification source-state evidence\n' | tee "${evidence_dir}/source-state.log" >&2
	exit 1
fi
if ! git -C "${source_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	printf 'source directory is not a git work tree: %s\n' "${source_dir}" | tee "${evidence_dir}/source-state.log" >&2
	exit 1
fi

nvidia_smi_bin="$(command -v nvidia-smi)"
{
	printf 'nvidia-smi=%s\n\n' "${nvidia_smi_bin}"
	"${nvidia_smi_bin}"
} 2>&1 | tee "${evidence_dir}/nvidia-smi.log"
"${nvidia_smi_bin}" -L 2>&1 | tee "${evidence_dir}/nvidia-smi-gpus.log"
if ! grep -Eq '^GPU [0-9]+:' "${evidence_dir}/nvidia-smi-gpus.log"; then
	printf 'nvidia-smi did not report any CUDA-capable GPU\n' >&2
	exit 1
fi

{
	cmake --version
	ctest --version
	if command -v nvcc >/dev/null 2>&1; then
		nvcc --version
	else
		printf 'nvcc not found in PATH; CMake may still use CMAKE_CUDA_COMPILER from OPENMVS_EXTRA_CMAKE_ARGS\n'
	fi
} > "${evidence_dir}/tool-versions.log" 2>&1

{
	printf 'git=%s\n' "$(command -v git)"
	printf 'source_dir=%s\n' "${source_dir}"
	printf 'git_top_level=%s\n' "$(git -C "${source_dir}" rev-parse --show-toplevel)"
	printf 'git_head=%s\n' "$(git -C "${source_dir}" rev-parse HEAD)"
	printf 'git_branch=%s\n' "$(git -C "${source_dir}" branch --show-current)"
	printf '\n## git status --short\n'
	git -C "${source_dir}" status --short
	printf '\n## git diff --stat\n'
	git -C "${source_dir}" diff --stat
	printf '\n## git diff --stat --cached\n'
	git -C "${source_dir}" diff --stat --cached
} > "${evidence_dir}/source-state.log" 2>&1

cmake_args=(
	-S "${source_dir}"
	-B "${build_dir}"
	-DOpenMVS_USE_CUDA=ON
	-DOpenMVS_REQUIRE_CUDA=ON
	-DOpenMVS_USE_METAL=OFF
	-DOpenMVS_ENABLE_TESTS=ON
	-DOpenMVS_HEADLESS_DEBUG=ON
	-DCMAKE_BUILD_TYPE="${build_type}"
)

if [[ -n "${OPENMVS_CUDA_GENERATOR:-}" ]]; then
	cmake_args+=(-G "${OPENMVS_CUDA_GENERATOR}")
fi

if [[ -n "${OPENMVS_CUDA_ARCHITECTURES:-}" ]]; then
	cmake_args+=(-DCMAKE_CUDA_ARCHITECTURES="${OPENMVS_CUDA_ARCHITECTURES}")
fi

if [[ -n "${OPENMVS_EXTRA_CMAKE_ARGS:-}" ]]; then
	# shellcheck disable=SC2206
	extra_args=(${OPENMVS_EXTRA_CMAKE_ARGS})
	cmake_args+=("${extra_args[@]}")
fi

export VCPKG_MAX_CONCURRENCY="${effective_vcpkg_max_concurrency}"

cmake "${cmake_args[@]}" 2>&1 | tee "${evidence_dir}/configure.log"

require_file_contains "${build_dir}/CMakeCache.txt" "OpenMVS_USE_CUDA:BOOL=ON"
require_file_contains "${build_dir}/CMakeCache.txt" "OpenMVS_REQUIRE_CUDA:BOOL=ON"
require_file_contains "${build_dir}/CMakeCache.txt" "OpenMVS_USE_METAL:BOOL=OFF"
require_file_contains "${build_dir}/ConfigLocal.h" "#define _USE_CUDA"
require_file_contains "${build_dir}/ConfigLocal.h" "/* #undef _USE_METAL */"
cp "${build_dir}/CMakeCache.txt" "${evidence_dir}/CMakeCache.txt"
cp "${build_dir}/ConfigLocal.h" "${evidence_dir}/ConfigLocal.h"
vcpkg_status="${build_dir}/vcpkg_installed/vcpkg/status"
vcpkg_manifest_log="${build_dir}/vcpkg-manifest-install.log"
require_vcpkg_status_feature "${vcpkg_status}" cuda core
require_vcpkg_status_feature "${vcpkg_status}" ceres cuda
require_vcpkg_status_feature "${vcpkg_status}" siftgpu cuda
cp "${vcpkg_status}" "${evidence_dir}/vcpkg-status"
if [[ -f "${vcpkg_manifest_log}" ]]; then
	cp "${vcpkg_manifest_log}" "${evidence_dir}/vcpkg-manifest-install.log"
fi

cmake --build "${build_dir}" \
	--config "${build_type}" \
	--target Tests DensifyPointCloud ReconstructMesh RefineMesh \
	--parallel "${build_jobs}" \
	2>&1 | tee "${evidence_dir}/build.log"

proof_test_regex='MVSPipelineCudaTest|MVSInProcessCpuCudaSpeedTest|MVSAppCpuCudaParityTest|MVSInvalidGpuBackendTest|MVSMetalCudaSurfaceAuditTest|SecondaryCudaSurfaceAuditTest|CudaVerifierSelfTest|CudaVerifierEarlyFailureSmokeTest'
registration="$(ctest --test-dir "${build_dir}" -N -R "${proof_test_regex}")"
printf '%s\n' "${registration}" | tee "${evidence_dir}/ctest-registration.log"
printf '%s\n' "${registration}" | grep -q 'MVSPipelineCudaTest'
printf '%s\n' "${registration}" | grep -q 'MVSInProcessCpuCudaSpeedTest'
printf '%s\n' "${registration}" | grep -q 'MVSAppCpuCudaParityTest'
printf '%s\n' "${registration}" | grep -q 'MVSInvalidGpuBackendTest'
printf '%s\n' "${registration}" | grep -q 'MVSMetalCudaSurfaceAuditTest'
printf '%s\n' "${registration}" | grep -q 'SecondaryCudaSurfaceAuditTest'
printf '%s\n' "${registration}" | grep -q 'CudaVerifierSelfTest'
printf '%s\n' "${registration}" | grep -q 'CudaVerifierEarlyFailureSmokeTest'

ctest --test-dir "${build_dir}" \
	--build-config "${build_type}" \
	--no-tests=error \
	-R "${proof_test_regex}" \
	--output-on-failure \
	--parallel "${ctest_jobs}" \
	--timeout "${ctest_timeout}" \
	-V \
	2>&1 | tee "${evidence_dir}/ctest.log"

require_file_contains "${evidence_dir}/ctest.log" "candidate DensifyPointCloud backend marker: cuda"
require_file_contains "${evidence_dir}/ctest.log" "candidate RefineMesh backend marker: cuda"
require_file_contains "${evidence_dir}/ctest.log" "candidate same-mesh RefineMesh backend marker: cuda"
require_file_contains "${evidence_dir}/ctest.log" "candidate MVSPipelineTest backend marker: cuda"
require_file_contains "${evidence_dir}/ctest.log" "DensifyPointCloud elapsed: reference="
require_file_contains "${evidence_dir}/ctest.log" "RefineMesh elapsed: reference="
require_file_contains "${evidence_dir}/ctest.log" "same-mesh RefineMesh elapsed: reference="
require_file_contains "${evidence_dir}/ctest.log" "MVSPipelineTest elapsed: reference="
grep -E 'backend marker: (cpu|cuda)|elapsed: reference=' "${evidence_dir}/ctest.log" \
	> "${evidence_dir}/backend-parity-summary.log"

{
	printf 'CUDA verification succeeded\n'
	printf 'source_dir=%s\n' "${source_dir}"
	printf 'build_dir=%s\n' "${build_dir}"
	printf 'build_type=%s\n' "${build_type}"
	printf 'build_jobs=%s\n' "${build_jobs}"
	printf 'vcpkg_jobs=%s\n' "${vcpkg_jobs}"
	printf 'ctest_jobs=%s\n' "${ctest_jobs}"
	printf 'ctest_timeout=%s\n' "${ctest_timeout}"
	printf 'VCPKG_MAX_CONCURRENCY=%s\n' "${VCPKG_MAX_CONCURRENCY}"
} > "${evidence_dir}/summary.txt"
write_evidence_manifest
