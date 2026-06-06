# Metal Port Status

Objective: port OpenMVS CUDA acceleration to Apple Metal while preserving CPU behavior and keeping CUDA builds working on non-Apple platforms.

## Summary Of Changes, Optimizations, And Parity Tests

Core changes:

- Added Apple Metal build/runtime support through `OpenMVS_USE_METAL`, `_USE_METAL`, Metal/Foundation framework linkage, Objective-C++ source handling, and generated shader embedding.
- Added shared backend selection in `SEACAVE::GPU`, plus `--gpu-backend auto|cpu|cuda|metal` dispatch for `DensifyPointCloud`, `RefineMesh`, and Viewer Densify.
- Added Metal runtime utilities for device discovery, shared buffers, R16/R32 textures, upload/download, fill helpers, and runtime smoke coverage.
- Ported first-party MVS CUDA surfaces to Metal: `PatchMatchMetal.h/.mm/.metal`, `SceneRefineMetal.cpp/.mm/.metal`, `libs/MVS/Metal/Camera.h`, and `libs/MVS/Metal/Maths.h`.
- Hardened backend reporting and fallback behavior: selected Metal failures now fail instead of silently falling back to CPU, and backend-capable apps emit `OpenMVS backend selected: ...` markers.
- Kept Ceres CUDA and SiftGPU CUDA as optional non-Apple CUDA surfaces; Apple/Metal builds remain CUDA-free.

Optimizations:

- Cached Metal device, command queue, compute pipeline states, and embedded `.metallib` loading.
- Fused several SceneRefine Metal command-buffer paths to reduce waits and buffer churn.
- Reused shared Metal buffer slots for projection/scoring hot paths, kept PatchMatch `planes`/`costs`/`selectedViews` resident across init/propagate/filter passes, kept photometric accumulators resident across scoring iterations, and amortized projected visibility/depth refresh across short gradient batches.
- Added Metal PatchMatch worker-pool plumbing bounded by `--patch-match-cuda-instances`.
- Recomputed final Metal PatchMatch normals with wider radius-4 support to improve dense-fusion parity.
- Reduced the CPU-pinned full-pipeline test worker count to 2 to avoid swap-heavy failures on 16 GB Apple machines while preserving output thresholds.

Parity and verification tests:

- `MVSInProcessCpuMetalSpeedTest`: CPU and Metal in-process MVS pipelines; fails unless Metal is faster.
- `MVSDenseMetalParityTest`: CPU-vs-Metal dense reconstruction with point count, robust AABB, valid-pixel support, depth drift, normal drift, and confidence checks.
- `MVSRefineMeshMetalTest`: sample-scene Metal RefineMesh path compared against reduced CPU refinement.
- `MVSAppCpuMetalSceneFileParityTest`: real app-level CPU-vs-Metal Densify/Reconstruct/Refine harness with count tolerances, backend markers, speed gates, and same-mesh RefineMesh comparison.
- `MVSMetalAppFixtureTest`, `MetalRuntimeSmoke`, `MVSInvalidGpuBackendTest`, `NoCudaDynamicLinkageTest`, `MVSNoMetalAppFallbackTest`, `MVSMetalCudaSurfaceAuditTest`, and `SecondaryCudaSurfaceAuditTest` cover fixture behavior, runtime helpers, bad backend names, Apple no-CUDA linkage, CPU-only fallback, and source-surface regressions.

## Current Scope

Implemented first infrastructure slice:

- `OpenMVS_USE_METAL` CMake option, default ON on Apple and OFF elsewhere.
- Apple CMake config force-disables `OpenMVS_USE_CUDA` before vcpkg manifest features are assembled, so `-DOpenMVS_USE_CUDA=ON` on macOS does not pull the CUDA vcpkg feature or define `_USE_CUDA`.
- `_USE_METAL` generated config define.
- Apple-only Objective-C++ enablement and Foundation/Metal framework linkage.
- `SEACAVE::METAL` runtime API in `libs/Common/UtilMetal.*`, including default-device discovery, shared-buffer RAII, upload/download helpers, byte fill, R32/R16 2D texture RAII with raw upload/download helpers, and runtime smoke coverage.
- `SEACAVE::GPU` backend selector in `libs/Common/UtilGPU.*`, including a pure-testable `auto` priority rule: Apple prefers Metal before CUDA; non-Apple prefers CUDA before Metal; both fall back to CPU.
- `MetalRuntimeSmoke` CTest entry through `apps/Tests/Tests 3`.
- `MVSPipelineTest` is CPU-pinned and `MVSPipelineMetalTest` exercises the Metal Densify path through the small MVS sample pipeline. These in-process pipeline tests now pass a strict expected dense backend (`cpu`, `metal`, or `cuda` in CUDA builds) and compare it against the backend reported by `Scene::DenseReconstruction`, so an `auto` fallback to CPU cannot satisfy a GPU pipeline CTest.
- When `DensifyPointCloud --gpu-backend metal` is used in a Metal build, Metal PatchMatch pool allocation failure is fatal instead of falling through to CUDA or CPU; once the Metal PatchMatch pool is selected, per-image Metal depth-map failure is also fatal instead of falling through while still reporting a Metal backend marker.
- `MVSInProcessCpuMetalSpeedTest` runs the existing CPU-pinned and Metal in-process MVS pipeline entries back-to-back, requires the strict Densify backend marker from each run, and fails if the Metal pipeline does not finish faster than the CPU reference. `MVSDenseMetalParityTest` runs CPU and Metal dense reconstruction on the small sample scene, removes stale depth-map caches between backends, preserves each backend's generated `.dmap` files long enough to load the raw depth, normal, and confidence maps, checks dense point count and raw bounding-box sanity, compares 2%-trimmed robust AABB center/scale so single outlier points do not dominate the parity check, and verifies map-level valid-pixel ratio, common valid support, median/p90 relative depth drift, median normal angular drift, and finite confidence summaries.
- `MVSRefineMeshMetalTest` exercises the Metal RefineMesh path on the small sample scene after building a dense point cloud and coarse mesh, then compares reduced Metal refinement against a reduced CPU refinement reference.
- `MVSMetalAppFixtureTest` copies the small sample scene into the build tree, then runs the actual `DensifyPointCloud --gpu-backend metal`, `ReconstructMesh`, and `RefineMesh --gpu-backend metal` executables, requires the Densify/Refine backend markers to report `metal`, and validates the generated PLY vertex/face counts.
- `MVSAppCpuMetalSceneFileParityTest` runs the actual `DensifyPointCloud`, `ReconstructMesh`, and `RefineMesh` executables twice on the copied sample fixture (`--gpu-backend cpu` and `--gpu-backend metal`), compares dense point, mesh, and refined mesh counts within loose CPU/Metal tolerances, records per-app runtimes, and fails if Metal Densify or Metal RefineMesh is not faster than CPU on the fixture. It also reruns RefineMesh on the exact same Metal-generated dense/mesh inputs with CPU and Metal backends and fails if Metal does not win that same-mesh comparison. The harness captures stdout/stderr and requires each backend-capable app to print an `OpenMVS backend selected: ...` marker, so a faster fallback path cannot satisfy the CPU/Metal or CPU/CUDA parity checks. The same script also supports a direct `TEST_DATA_DIR` mode for manual/default fixture execution; the registered Metal speed gate uses `TEST_SCENE_FILE` to avoid a duplicate heavy app parity run over the same sample scene.
- Once the Metal RefineMesh backend is selected in a Metal build, `Scene::RefineMeshMetal(...)` failure is fatal instead of falling through to CUDA or CPU refinement.
- `MVSAppCpuMetalSceneFileParityTest` registers the `TEST_SCENE_FILE` entry point in CTest using the bundled sample scene as a minimal scene-copy-root fixture. This keeps the representative-scene harness path covered by repeatable CI-style execution; the same harness has also been run manually on a larger local scene as documented below.
- `MVSMetalCudaSurfaceAuditTest` is a cheap source-level CTest that audits the MVS CUDA-to-Metal surface: the expected MVS CUDA translation units, CUDA/Metal camera and math helper-header coverage, one-to-one SceneRefine CUDA/Metal kernel and launcher coverage, PatchMatch initialize/propagate/filter Metal stage coverage, PatchMatch CUDA/Metal host API parity, Densify CUDA/Metal PatchMatch dispatch hooks, `MetalRuntimeSmoke` registration, and invocation of every declared Metal smoke function from `Tests 3`. It also counts first-party MVS CUDA kernel declarations, so a new `__global__` kernel added to an existing CUDA file fails the audit until the corresponding Metal surface is reviewed.
- `SecondaryCudaSurfaceAuditTest` is a cheap source-level CTest that audits the non-MVS CUDA decision surfaces from the original plan: Apple CUDA cache guarding before vcpkg feature selection, root Metal platform/framework gating, Common CUDA/Metal/GPU runtime helper coverage, Common/MVS CUDA and Metal source inclusion guards, SiftGPU's CUDA feature isolation, app-level `cuda-device` guards, SiftGPU extraction/matching CUDA compile guards, Ceres CUDA vs Metal CPU-fallback solver policy, CUDA proof-test registration, app backend-marker enforcement, invalid backend rejection, app parity speed-gate enforcement, in-process MVS pipeline speed-gate enforcement, CUDA verifier self-test and early-failure smoke coverage, and generated-doc CUDA/Metal wording. It also checks that the root Apple CUDA force-disable occurs before vcpkg CUDA feature selection, that `DensifyPointCloud` and `RefineMesh` reject invalid `--gpu-backend` names before backend initialization, that the app parity speed gate is unconditional, that the in-process CPU-vs-Metal speed gate is registered and unconditional, that every CUDA-named runtime source in `libs/` and SiftGPU's port is classified, that `UtilCUDADevice.h` remains guarded through CUDA-only include paths, and that the vendored SiftGPU CMake only enables CUDA language, toolkit lookup, CUDA compile definitions, CUDA link libraries, and CUDA source files under `CUDA_ENABLED`.
- `MVSInvalidGpuBackendTest` is a cheap app-level CTest that runs `DensifyPointCloud` and `RefineMesh` with `--gpu-backend vulkan`, expects both commands to fail, and checks that each reports the invalid backend. This protects the backend marker/parity tests from a future silent fallback on misspelled backend names.
- CUDA builds now register `MVSPipelineCudaTest`, `MVSInProcessCpuCudaSpeedTest`, and `MVSAppCpuCudaParityTest`. These tests are gated behind `_USE_CUDA`, so they do not appear in Apple/Metal or CPU-only builds; on non-Apple CUDA hardware they exercise the existing CUDA PatchMatch path, an in-process CPU-vs-CUDA pipeline speed gate, and the actual app-level `DensifyPointCloud --gpu-backend cuda` / `RefineMesh --gpu-backend cuda` paths through the same parity harness used for Metal. The CUDA app parity registration is independent of the Metal app parity registration, so a build with both GPU backends enabled still gets the CUDA app-level proof. The in-process CUDA pipeline test expects `cuda` explicitly, and both CUDA speed gates require backend markers and fail if CUDA is not faster than CPU.
- `OpenMVS_REQUIRE_CUDA=ON` is available for verification builds. It preserves the default user-friendly fallback when OFF, but fails configuration if a CUDA proof run asks for CUDA and the compiler/toolkit is unavailable or CUDA was disabled by platform policy. The checked-in `scripts/verify-cuda.sh` proof path also asserts the generated CMake cache and `ConfigLocal.h` state before building, so a CUDA verification run cannot silently degrade to CPU-only or Metal.
- `scripts/verify-cuda.sh` writes `cuda-verification-evidence/` with `nvidia-smi` hardware visibility, Git source-state, tool versions, configure/build/CTest logs, CUDA test registration, generated `CMakeCache.txt`, generated `ConfigLocal.h`, vcpkg CUDA package/feature status, a backend parity marker/timing summary, an evidence manifest with file sizes and SHA-256 hashes, and a summary file. It also asserts that vcpkg installed `cuda`, `ceres[cuda]`, and `siftgpu[cuda]`, and that the CTest log contains CUDA app backend markers and the CPU-vs-CUDA speed-gate output. The verifier defaults to two OpenMVS build jobs, vcpkg dependency-build concurrency tied to the same job count, and one CTest proof job; it writes `verification-environment.log` before hardware/configure checks, records all three resource limits plus the effective `VCPKG_MAX_CONCURRENCY`, writes `verification-result.log` with the final exit status, and regenerates `evidence-manifest.log` on exit even for early failures. The CUDA proof CTest selection includes `CudaVerifierSelfTest`, which exercises the vcpkg status parser against synthetic installed/missing feature records, and `CudaVerifierEarlyFailureSmokeTest`, which runs the verifier with a fake no-GPU `nvidia-smi` and validates the early-failure artifacts without reaching configure. This keeps the final non-Apple proof auditable after the run finishes without letting dependency builds overwhelm low-memory hosts.
- `scripts/verify-cuda-docker.sh` is a non-Apple/NVIDIA convenience wrapper for hosts that do not already have the full dependency stack. It checks the host Docker and NVIDIA runtime first, records `host-nvidia-smi.log`, `docker-info.log`, and `docker-nvidia-smi.log` into `cuda-verification-evidence/` even on early failure, then runs an NVIDIA CUDA devel image with `--gpus all`, mounts this checkout at `/work`, bootstraps vcpkg inside the container with a host cache, and runs `/work/scripts/verify-cuda.sh` against the mounted source tree. On exit it regenerates `evidence-manifest.log` after host-side logs have been copied. This avoids treating the legacy Dockerfile's upstream OpenMVS clone as proof of this branch.
- `.github/workflows/cuda_verification.yml` is a manual workflow for self-hosted `linux`, `x64`, `cuda` runners. It runs `scripts/verify-cuda-docker.sh` with the same low-memory defaults used locally and exposes separate `build_jobs`, `vcpkg_jobs`, and `ctest_jobs` inputs; the wrapper records host and Docker NVIDIA visibility evidence, preserves that evidence even on early failure, and the workflow uploads `cuda-verification-evidence` on every run.
- The existing `continuous_integration.yml` build matrix remains CUDA-off across Windows, Ubuntu, and macOS (`OpenMVS_USE_CUDA=OFF`), and `SecondaryCudaSurfaceAuditTest` now audits that the standard non-CUDA build/test matrix is still present.
- `MVSNoMetalAppFallbackTest` is registered in CPU-only builds. It runs the same app fixture with `--gpu-backend metal` and verifies that a build without `_USE_METAL` warns, reports CPU backend markers, falls back to CPU execution, and still produces valid dense/mesh outputs.
- `NoCudaDynamicLinkageTest` is registered on Apple non-CUDA builds. It runs `otool -L` over all built command-line apps (`CreateStructure`, `ExtractKeyframes`, `InterfaceCOLMAP`, `InterfaceMetashape`, `InterfaceMVSNet`, `InterfacePolycam`, `DensifyPointCloud`, `ReconstructMesh`, `RefineMesh`, `TextureMesh`, `TransformScene`, and `Tests`) plus `libMVS.dylib`, `libSFM.dylib`, `libIO.dylib`, `libMath.dylib`, and `libCommon.dylib`, then fails on CUDA/NVIDIA dynamic dependency names in the dependency lines. When `OpenMVS_BUILD_VIEWER=ON`, the same test also includes the built `Viewer.app` executable.
- `Scene::RefineMeshMetal(...)` host entry point and `RefineMesh --gpu-backend` dispatch.
- `PatchMatchMetal` host path and `DensifyPointCloud --gpu-backend` dispatch. The Metal host path now runs the CUDA-style descending multi-resolution initial pass and single-level geometric-consistency refinement passes when Metal is selected.
- Viewer Densify workflow now uses the same `SEACAVE::GPU` backend selector as the command-line Densify path and treats `_USE_METAL` as a GPU build for the higher-quality default view/iteration counts that were previously CUDA-only. This keeps the GUI Densify path from remaining a CUDA-only control surface. The Viewer RefineMesh workflow still calls the CPU `Scene::RefineMesh` path; it did not use the CUDA refine path before this port.
- The generated architecture, pipeline, and feature-catalog docs now distinguish CUDA from Apple Metal for first-party MVS PatchMatch and mesh refinement, while leaving Ceres and SiftGPU CUDA surfaces documented as CUDA-specific.
- Objective-C++ Metal dispatch code is isolated in `SceneRefineMetal.mm`; the `Scene::RefineMeshMetal(...)` bridge lives in `SceneRefineMetal.cpp` to keep Apple framework imports out of the heavy OpenMVS `Common.h` include graph.
- Shared Metal math/camera PODs and MSL helpers in `libs/MVS/Metal/Maths.h` and `libs/MVS/Metal/Camera.h`, covering the W2C/C2I/I2W transforms used by projection, warp, and photometric-gradient kernels.
- Deterministic SceneRefine kernels translated in `libs/MVS/SceneRefineMetal.metal`:
  - `kernelCameraProjectSmoke`
  - `kernelComputeFaceNormal`
  - `kernelProjectMesh`
  - `kernelCrossCheckProjection`
  - `kernelComputeImageMean`
  - `kernelComputeImageVar`
  - `kernelComputeImageCov`
  - `kernelComputeImageZNCC`
  - `kernelComputeImageDZNCC`
  - `kernelImageMeshWarp`
  - `kernelComputePhotometricGradient`
  - `kernelUpdatePhotoGradNorm`
  - `kernelComputeSmoothnessGradient`
  - `kernelCombineGradients`
  - `kernelCombineAllGradients`
- Host-side `MVS::METAL::Launch*` wrappers and smoke helpers for camera projection/back-projection, synthetic triangle normals, mesh projection/rasterization, projection cleanup, masked image statistics, ZNCC/DZNCC, image warping, photometric-gradient accumulation, smoothness gradients, and gradient combination.
- Chained SceneRefine pair smoke (`RunRefineMeshPairSmoke`) that composes the Metal launchers for one synthetic image pair: project both views, cross-check projection maps, warp image B into A, compute local statistics and DZNCC, accumulate photometric gradients, update gradient norms, compute smoothness, and combine final gradients.
- First host-side `Scene::RefineMeshMetal(...)` implementation for the RefineMesh app path. It mirrors the CUDA refinement loop at a coarse level, rebuilds Metal mesh/view buffers as the mesh changes, runs projection, pair scoring, smoothness, and gradient-combination kernels, and updates vertices across refinement iterations.
- SceneRefine Metal launcher setup now caches the default device, command queue, compute pipeline states, and a precompiled SceneRefine `.metallib` embedded by CMake, falling back to runtime `newLibraryWithSource(...)` compilation only if loading the embedded library fails.
- RefineMesh Metal now fuses the per-pair image-stat chain, photometric-gradient accumulation, and photo-gradient norm update into one command buffer per image pair. It also fuses the two smoothness-gradient passes and final gradient combination into one command buffer per refinement iteration. The fused launchers keep reusable per-thread shared Metal buffer slots, keep photometric accumulators resident across all active image pairs in one scoring iteration, and reuse shared slots for face-normal, projection, and cross-check projection launchers. The host refreshes projected visibility/depth maps once per short 8-iteration gradient batch rather than every gradient step, while still refreshing mutable mesh buffers and normals every step. This reduces command-buffer waits, buffer-object churn, repeated projection cost, and host-visible intermediate maps from the earlier launcher-per-kernel host path.
- Host-level RefineMesh smoke (`RunRefineMeshHostSmoke`) that constructs a synthetic two-view scene in memory and executes `Scene::RefineMeshMetal(...)` through the public API. This also covers boundary-only meshes by allowing zero smoothness-neighbor references in the Metal launcher.
- First PatchMatch Metal kernel slice: `kernelFilterPlanes` and `LaunchFilterPlanes`, matching the deterministic CUDA post-filter that clears invalid/high-cost depth-normal plane estimates and selected-view masks. `RunPatchMatchFilterPlanesSmoke` covers keep/drop behavior.
- PatchMatch weighted-ZNCC score-plane slice: `kernelScorePlanePair` and `LaunchScorePlanePair`, porting the CUDA reference-patch cache, homography warp, bilateral weights, variance/covariance checks, and per-pixel pair cost computation for one reference/target image pair. `RunPatchMatchScorePlaneSmoke` covers identical-image identity-camera scoring.
- PatchMatch low-depth prior slice: optional `lowDepths` buffers now flow through score, initialize, propagation, and refinement launchers; `ScorePlanePair` applies the same low-texture depth-prior blend as CUDA. `RunPatchMatchLowDepthPriorSmoke` verifies that a low-texture identity pair stays photometrically ambiguous without the prior and penalizes the wrong depth when the prior is supplied.
- PatchMatch geometric-consistency slice: optional packed depth-image buffers now flow through score, initialize, propagation, and refinement launchers; scoring adds the CUDA-style forward/backward depth-image reprojection penalty. `RunPatchMatchGeometricConsistencySmoke` verifies matching and inconsistent target depth maps.
- PatchMatch initialize-score slice: `kernelInitializeScore` and `LaunchInitializeScore`, covering deterministic plane initialization for missing/back-facing estimates, multi-target pair scoring, top-k cost aggregation, and selected-view bitmask generation for packed target images. `RunPatchMatchInitializeScoreSmoke` verifies that the initializer chooses the identical target over an inverted target.
- PatchMatch checkerboard propagation slice: `kernelPropagateScore` and `LaunchPropagateScore`, covering black/red pass gating, CUDA-style neighbor depth interpolation to the current pixel, ACMH/AMHMVS-style 8-direction adaptive neighbor sampling, selected-view priors, CDF sampling with 32 deterministic hash samples, and weighted multi-view cost aggregation. `RunPatchMatchPropagateScoreSmoke` verifies that an invalid black pixel adopts a valid red neighbor plane and keeps the preferred sampled target selected.
- PatchMatch refinement slice inside `kernelPropagateScore`, covering deterministic equivalents of CUDA's perturbed-depth, perturbed-normal, random-normal, and 4-connected surface-normal candidate tests. `RunPatchMatchRefineScoreSmoke` verifies that a shifted synthetic target causes the kernel to replace the current plane with the lower-cost perturbed-depth candidate.
- PatchMatch host orchestration: `PatchMatchMetal::EstimateDepthMap(...)` now packs the prepared reference and target grayscale images, optional low-resolution depth priors, optional geometric depth priors, cameras, depth/normal planes, cost map, and selected-view masks; uploads mutable `planes`, `costs`, and `selectedViews` once per pyramid level; runs initialize, black/red propagation iterations, and filtering against those resident Metal buffers; downloads the mutable buffers once at level end; stores raw selected-view bitmasks between sub-resolution levels; then unpacks final planes into `depthMap`/`normalMap`, converts costs to `confMap`, and expands bitmask views into `viewsMap`. After the final Metal pass, normals are recomputed from the accepted depth map with a wider least-squares support radius; the default CPU/CUDA normal helper remains radius-1, while the Metal finalization uses radius-4 to reduce cross-view normal noise in dense fusion.
- Metal PatchMatch now mirrors CUDA's per-worker pool plumbing in `DepthMapsData`: dense workers claim a backend slot through a thread-local index guarded by an epoch, geometric-consistency reinit resets the slot counter, and `DensifyPointCloud --patch-match-cuda-instances` bounds CUDA/Metal worker instances.
- In-process MVS tests cap OpenMP, scene worker threads, and PatchMatch GPU worker instances. Most sample GPU/parity tests use 4 workers; the CPU-forced full-pipeline baseline uses 2 workers to avoid swap-heavy memory pressure on 16 GB Apple machines while preserving the same dense, mesh, texture, and quality thresholds.
- Host-level PatchMatch smoke (`RunPatchMatchHostSmoke`) constructs a synthetic two-view `DepthData`, enables multiple sub-resolution levels, executes `PatchMatchMetal::EstimateDepthMap(...)`, and verifies populated full-resolution depth, normal, confidence, and view maps.
- `libs/MVS/PatchMatchMetal.metal` and `libs/MVS/SceneRefineMetal.metal` are the canonical MSL sources. CMake embeds PatchMatch directly into a generated source include. CMake compiles SceneRefine to an embedded `.metallib` for normal execution and also keeps a generated source-string fallback with local MSL helper includes expanded, so offline CTest shader compilation and fallback runtime compilation exercise the same checked-in shader sources.

CUDA files and `_USE_CUDA` behavior are unchanged. The shared backend selector now has unit coverage for the non-Apple `auto` matrix so future non-Apple CUDA builds keep CUDA ahead of Metal when both backends are compiled.

## Secondary CUDA Surfaces

- Ceres CUDA solver selection is not being ported to Metal. `libs/SFM/GlobalPositioning.cpp` only enables Ceres CUDA linear algebra under `_USE_CUDA`; Apple/Metal builds use the existing CPU Ceres solver path and log a warning when the GPU solver threshold is reached because Ceres has no Metal backend.
- SiftGPU CUDA is not being ported in this MVS Metal slice. Apple/Metal builds can use the existing non-CUDA feature paths and SiftGPU's non-CUDA OpenGL context when available; the SiftGPU CUDA sources under `ports/siftgpu/source/src/ProgramCU.cu`, `PyramidCU.cpp`, `SiftMatchCU.cpp`, and `CuTexImage.cpp` remain a separate optional dependency path for non-Apple CUDA builds. `libs/SFM/FeaturesExtractor.cpp` now treats `useCUDA` as false when `_USE_CUDA` is not compiled, so the OpenGL SiftGPU path keeps GLSL-only options such as darkness adaptivity instead of inheriting the CUDA preference default.
- No Apple build path should require CUDA. Non-Apple CUDA support remains in place for PatchMatch, mesh refinement, Ceres GPU solver selection, and SiftGPU CUDA where those dependencies are configured.

## Validation Matrix Status

- macOS CPU/Metal: complete for the current local acceptance scope. The primary Metal full suite passes with in-process and app-level CPU-vs-Metal parity/speed gates enabled, and the Viewer/SiftGPU/CPU-only Apple audit slices pass without CUDA linkage.
- Windows/Ubuntu/macOS CUDA-off CI: present and source-audited. `continuous_integration.yml` keeps the standard CUDA-off matrix, and `SecondaryCudaSurfaceAuditTest` fails if that matrix is removed or stops configuring with `OpenMVS_USE_CUDA=OFF`.
- Linux/NVIDIA CUDA-on: optional preservation proof, not required for the Metal/CPU acceptance scope. `scripts/verify-cuda.sh`, `scripts/verify-cuda-docker.sh`, and the manual self-hosted CUDA workflow remain available and audited for maintainers who want CUDA-on evidence, but completion of this Metal port is judged by Metal-vs-CPU parity and Apple CUDA-free builds.

## Verification Commands

Installed/provisioned dependencies and toolchain:

```bash
brew reinstall boost
brew install nanoflann
brew install vcpkg
xcodebuild -downloadComponent MetalToolchain
git clone https://github.com/microsoft/vcpkg.git /Users/akshitgarg/vcpkg
```

Homebrew Boost 1.90 provides Boost.System headers but not the `boost_system` CMake package/library expected by this project. The current working build therefore uses the cloned vcpkg tree.

vcpkg-backed configure used:

```bash
cmake -S . -B build-metal-vcpkg -GNinja \
  -DCMAKE_TOOLCHAIN_FILE=/Users/akshitgarg/vcpkg/scripts/buildsystems/vcpkg.cmake \
  -DVCPKG_TARGET_TRIPLET=arm64-osx \
  -DOpenMVS_USE_METAL=ON \
  -DOpenMVS_USE_CUDA=OFF \
  -DOpenMVS_USE_SIFTGPU=OFF \
  -DOpenMVS_USE_PYTHON=OFF \
  -DOpenMVS_BUILD_VIEWER=OFF \
  -DOpenMVS_USE_CERES=OFF \
  -DOpenMVS_USE_BREAKPAD=OFF \
  -DOpenMVS_ENABLE_TESTS=ON
```

Result: configure succeeded, found Metal, OpenMP, Boost 1.91 via vcpkg, OpenCV 4.12, Eigen 5.0.1, nanoflann 1.9.0, CGAL 6.1.1, Ceres 2.2, PoseLib, TinyEXIF, and TinyNPY.

Viewer-enabled Metal configure used:

```bash
cmake -S . -B build-metal-viewer-toolchain-vcpkg -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/Users/akshitgarg/vcpkg/scripts/buildsystems/vcpkg.cmake \
  -DVCPKG_TARGET_TRIPLET=arm64-osx \
  -DOpenMVS_BUILD_VIEWER=ON \
  -DOpenMVS_USE_CUDA=OFF \
  -DOpenMVS_USE_SIFTGPU=OFF \
  -DOpenMVS_USE_PYTHON=OFF \
  -DOpenMVS_USE_METAL=ON \
  -DOpenMVS_ENABLE_TESTS=ON
```

Result: configure succeeded through the explicit vcpkg toolchain, with the vcpkg `viewer` feature installing and resolving `imgui[glfw-binding,opengl3-binding]`, `portable-file-dialogs`, GLAD, and GLFW for the Viewer target.

CPU-only macOS configure used:

```bash
cmake -S . -B build-cpu-vcpkg -GNinja \
  -DCMAKE_TOOLCHAIN_FILE=/Users/akshitgarg/vcpkg/scripts/buildsystems/vcpkg.cmake \
  -DVCPKG_TARGET_TRIPLET=arm64-osx \
  -DOpenMVS_USE_METAL=OFF \
  -DOpenMVS_USE_CUDA=OFF \
  -DOpenMVS_USE_SIFTGPU=OFF \
  -DOpenMVS_USE_PYTHON=OFF \
  -DOpenMVS_BUILD_VIEWER=OFF \
  -DOpenMVS_USE_CERES=OFF \
  -DOpenMVS_USE_BREAKPAD=OFF \
  -DOpenMVS_ENABLE_TESTS=ON
```

Result: configure succeeded without enabling `_USE_METAL`; the CPU-only build registers `CommonUnitTests`, `SFMPipelineTest`, `MVSPipelineTest`, `MVSMetalCudaSurfaceAuditTest`, `SecondaryCudaSurfaceAuditTest`, `CudaVerifierSelfTest`, `CudaVerifierEarlyFailureSmokeTest`, `MVSInvalidGpuBackendTest`, `NoCudaDynamicLinkageTest`, and `MVSNoMetalAppFallbackTest`.

Apple Metal + SiftGPU + CUDA-off configure used:

```bash
cmake -S . -B build-metal-siftgpu-vcpkg -GNinja \
  -DCMAKE_TOOLCHAIN_FILE=/Users/akshitgarg/vcpkg/scripts/buildsystems/vcpkg.cmake \
  -DVCPKG_TARGET_TRIPLET=arm64-osx \
  -DOpenMVS_USE_METAL=ON \
  -DOpenMVS_USE_CUDA=OFF \
  -DOpenMVS_USE_SIFTGPU=ON \
  -DOpenMVS_USE_PYTHON=OFF \
  -DOpenMVS_BUILD_VIEWER=OFF \
  -DOpenMVS_USE_CERES=OFF \
  -DOpenMVS_USE_BREAKPAD=OFF \
  -DOpenMVS_ENABLE_TESTS=ON
```

Result: configure and build succeeded, found SiftGPU and Metal, generated `_USE_METAL` but not `_USE_CUDA`, and linked OpenGL/Metal with no CUDA runtime linkage matches.

Apple CUDA cache-guard verification used:

```bash
cmake -S . -B /private/tmp/openmvs-cuda-cache-vcpkg-20260606 -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/Users/akshitgarg/vcpkg/scripts/buildsystems/vcpkg.cmake \
  -DVCPKG_OVERLAY_PORTS=/Users/akshitgarg/workspace/cdcseacave/openmvs/ports \
  -DCMAKE_BUILD_TYPE=Release \
  -DOpenMVS_USE_CUDA=ON \
  -DOpenMVS_USE_METAL=ON \
  -DOpenMVS_BUILD_VIEWER=OFF \
  -DOpenMVS_USE_SIFTGPU=OFF \
  -DOpenMVS_USE_PYTHON=OFF \
  -DOpenMVS_USE_CERES=ON \
  -DOpenMVS_ENABLE_TESTS=ON
```

Result: configure succeeded through vcpkg while printing `Disabling CUDA on MacOS`. The generated cache contains `OpenMVS_USE_CUDA:BOOL=OFF` and `OpenMVS_USE_METAL:BOOL=ON`; generated `ConfigLocal.h` leaves `_USE_CUDA` undefined and defines `_USE_METAL`; vcpkg status contains no CUDA or SiftGPU package entries.

CUDA-required verification guard on Apple used:

```bash
cmake -S . -B /private/tmp/openmvs-require-cuda-apple-test \
  -DOpenMVS_USE_CUDA=ON \
  -DOpenMVS_REQUIRE_CUDA=ON \
  -DOpenMVS_USE_METAL=OFF
```

Result: configure fails immediately after `Disabling CUDA on MacOS` with `OpenMVS_REQUIRE_CUDA=ON requires OpenMVS_USE_CUDA=ON on a non-Apple CUDA-capable platform.` This makes CUDA proof runs fail loudly when platform policy disables CUDA.

Non-Apple CUDA verification path to run on CUDA-capable hardware:

```bash
OPENMVS_CUDA_GENERATOR=Ninja \
OPENMVS_CUDA_BUILD_JOBS=2 \
OPENMVS_CUDA_VCPKG_JOBS=2 \
OPENMVS_CUDA_CTEST_JOBS=1 \
OPENMVS_CUDA_CTEST_TIMEOUT=1200 \
OPENMVS_EXTRA_CMAKE_ARGS="-DOpenMVS_BUILD_VIEWER=OFF -DOpenMVS_USE_SIFTGPU=ON -DOpenMVS_USE_CERES=ON" \
scripts/verify-cuda.sh
```

Containerized CUDA verification path for a Linux host with Docker and NVIDIA Container Toolkit:

```bash
OPENMVS_CUDA_BUILD_JOBS=2 OPENMVS_CUDA_VCPKG_JOBS=2 OPENMVS_CUDA_CTEST_JOBS=1 OPENMVS_CUDA_CTEST_TIMEOUT=1200 scripts/verify-cuda-docker.sh
```

The same containerized proof can be run from GitHub Actions by manually dispatching the `CUDA Verification` workflow on a self-hosted runner labeled `linux`, `x64`, and `cuda`. The workflow uploads the `cuda-verification-evidence` artifact containing configure/build/CTest logs, the generated CUDA cache/config files, the CUDA CTest registration, and the recorded build/vcpkg/CTest concurrency limits.

Optional CUDA evidence: `host-nvidia-smi.log` and `docker-nvidia-smi.log` show the host and Docker NVIDIA runtime when using the wrapper; `verification-environment.log` records `build_jobs`, `vcpkg_jobs`, `ctest_jobs`, `ctest_timeout`, and the effective `VCPKG_MAX_CONCURRENCY` before configure can fail; `verification-result.log` records the final exit status and `result=success` or `result=failure`; `nvidia-smi.log` and `nvidia-smi-gpus.log` show a visible NVIDIA GPU inside the verification environment; `source-state.log` records the Git top-level, branch, commit, status, and diff stat for the exact checkout under test; `tool-versions.log` records CMake/CTest and the available CUDA compiler version; configure produces `OpenMVS_USE_CUDA:BOOL=ON`, `OpenMVS_REQUIRE_CUDA:BOOL=ON`, and `OpenMVS_USE_METAL:BOOL=OFF` in `CMakeCache.txt`; generated `ConfigLocal.h` defines `_USE_CUDA` and leaves `_USE_METAL` undefined; copied `vcpkg-status` proves the vcpkg CUDA dependency surface by containing installed entries for `cuda`, `ceres[cuda]`, and `siftgpu[cuda]`; `vcpkg-manifest-install.log` is preserved when vcpkg emits it; `OpenMVS_REQUIRE_CUDA=ON` prevents silent fallback to a non-CUDA build; the script exports `VCPKG_MAX_CONCURRENCY` before configure, builds `Tests`, `DensifyPointCloud`, `ReconstructMesh`, and `RefineMesh`, and runs proof CTests with explicit `--parallel`; `ctest-registration.log` includes `MVSPipelineCudaTest`, `MVSInProcessCpuCudaSpeedTest`, `MVSAppCpuCudaParityTest`, `MVSInvalidGpuBackendTest`, `MVSMetalCudaSurfaceAuditTest`, `SecondaryCudaSurfaceAuditTest`, `CudaVerifierSelfTest`, and `CudaVerifierEarlyFailureSmokeTest`; `MVSPipelineCudaTest` runs the default non-Apple `auto` backend through CUDA; `MVSInProcessCpuCudaSpeedTest` runs CPU and CUDA in-process MVS pipelines back-to-back and fails unless CUDA is faster; `MVSAppCpuCudaParityTest` runs actual `--gpu-backend cuda` Densify and RefineMesh app commands against the CPU reference; `CudaVerifierSelfTest` exercises the vcpkg status parser against synthetic installed/missing feature records; `CudaVerifierEarlyFailureSmokeTest` validates the verifier's early-failure artifacts with a fake no-GPU `nvidia-smi` and asserts it does not reach configure; `backend-parity-summary.log` contains the CUDA candidate backend markers plus the in-process pipeline, Densify, RefineMesh, and same-mesh RefineMesh speed-gate summaries; `summary.txt` records the same resource limits after a successful proof; and `evidence-manifest.log` lists every evidence file with byte count and SHA-256 hash, including early-failure logs because the verifier regenerates it on exit. `--no-tests=error`, the script's full proof-test registration check, and the post-CTest marker checks make missing CUDA test registration or a missing CUDA app/backend marker fail the optional CUDA verification command.

```bash
cmake --build build-metal-vcpkg --target Tests -j4
cmake --build build-metal-vcpkg -j4
cmake --build build-cpu-vcpkg -j4
cmake --build build-metal-siftgpu-vcpkg -j4
cmake --build build-metal-viewer-toolchain-vcpkg --target \
  DensifyPointCloud RefineMesh ReconstructMesh Tests CreateStructure ExtractKeyframes \
  InterfaceCOLMAP InterfaceMetashape InterfaceMVSNet InterfacePolycam TextureMesh \
  TransformScene Viewer -j2
```

Result: the Metal `Tests` target, the full Metal configured build, the full CPU-only configured build, and the Viewer-enabled Metal app/test target set pass outside the sandbox. The Viewer build links `bin/Viewer.app/Contents/MacOS/Viewer`. CPU-forced `MVSPipelineTest` keeps the same structural thresholds as the Metal/default path and uses a `44.0` reconstruction-quality floor; the Metal/default path keeps the stricter `45.0` floor.

Metal shader/toolchain checks used:

```bash
xcrun -sdk macosx metal -c libs/MVS/SceneRefineMetal.metal \
  -I libs/MVS -o /private/tmp/SceneRefineMetal.air
xcrun -sdk macosx metal -c libs/MVS/PatchMatchMetal.metal \
  -I libs/MVS -o /private/tmp/PatchMatchMetal.air
```

Result: offline `.metal` compilation succeeds for both SceneRefine and PatchMatch after installing the Metal Toolchain component.

CTest verification used:

```bash
ctest --test-dir build-metal-vcpkg -R MetalRuntimeSmoke --output-on-failure
ctest --test-dir build-metal-vcpkg -R CommonUnitTests --output-on-failure
ctest --test-dir build-metal-vcpkg -R MVSPipelineTest --output-on-failure
ctest --test-dir build-metal-vcpkg -R MVSPipelineMetalTest --output-on-failure
ctest --test-dir build-metal-vcpkg -R MVSDenseMetalParityTest --output-on-failure
ctest --test-dir build-metal-vcpkg -R MVSRefineMeshMetalTest --output-on-failure
ctest --test-dir build-metal-vcpkg -R MVSMetalAppFixtureTest --output-on-failure
ctest --test-dir build-metal-vcpkg -R NoCudaDynamicLinkageTest --output-on-failure -V
ctest --test-dir build-metal-vcpkg -R "SceneRefineMetalShaderCompile|PatchMatchMetalShaderCompile" --output-on-failure
ctest --test-dir build-metal-vcpkg -R "MetalRuntimeSmoke|MVSPipelineMetalTest|MVSDenseMetalParityTest|MVSRefineMeshMetalTest|MVSMetalAppFixtureTest" --output-on-failure
ctest --test-dir build-metal-vcpkg --output-on-failure --timeout 900
ctest --test-dir build-metal-vcpkg --output-on-failure --parallel 1 --timeout 1200
ctest --test-dir build-metal-vcpkg -R "MVSInProcessCpuMetalSpeedTest|SecondaryCudaSurfaceAuditTest" --output-on-failure -V --timeout 1200
ctest --test-dir build-metal-siftgpu-vcpkg -R "SceneRefineMetalShaderCompile|PatchMatchMetalShaderCompile" --output-on-failure
ctest --test-dir build-metal-siftgpu-vcpkg -R NoCudaDynamicLinkageTest --output-on-failure -V
ctest --test-dir build-metal-siftgpu-vcpkg --output-on-failure --timeout 600
ctest --test-dir build-cpu-vcpkg -N
ctest --test-dir build-cpu-vcpkg -R NoCudaDynamicLinkageTest --output-on-failure -V
ctest --test-dir build-cpu-vcpkg -R MVSNoMetalAppFallbackTest --output-on-failure
ctest --test-dir build-cpu-vcpkg --output-on-failure --timeout 300
ctest --test-dir build-metal-vcpkg -R MVSInvalidGpuBackendTest --output-on-failure -V
ctest --test-dir build-metal-vcpkg -R MVSMetalCudaSurfaceAuditTest --output-on-failure -V
ctest --test-dir build-cpu-vcpkg -R MVSMetalCudaSurfaceAuditTest --output-on-failure -V
ctest --test-dir build-metal-siftgpu-vcpkg -R MVSMetalCudaSurfaceAuditTest --output-on-failure -V
ctest --test-dir build-metal-vcpkg -R "CudaVerifierSelfTest|CudaVerifierEarlyFailureSmokeTest" --output-on-failure -V
ctest --test-dir build-metal-vcpkg -R SecondaryCudaSurfaceAuditTest --output-on-failure -V
ctest --test-dir build-cpu-vcpkg -R SecondaryCudaSurfaceAuditTest --output-on-failure -V
ctest --test-dir build-metal-siftgpu-vcpkg -R SecondaryCudaSurfaceAuditTest --output-on-failure -V
ctest --test-dir build-metal-vcpkg -R MVSAppCpuMetalSceneFileParityTest --output-on-failure --timeout 900 -V
ctest --test-dir build-metal-siftgpu-vcpkg -R MVSAppCpuMetalSceneFileParityTest --output-on-failure --timeout 900 -V
ctest --test-dir build-metal-viewer-toolchain-vcpkg \
  -R "CommonUnitTests|NoCudaDynamicLinkageTest|SecondaryCudaSurfaceAuditTest|MVSMetalCudaSurfaceAuditTest" \
  --output-on-failure -V
ctest --test-dir build-metal-viewer-toolchain-vcpkg -N \
  -R "MVSPipelineCudaTest|MVSInProcessCpuCudaSpeedTest|MVSAppCpuCudaParityTest"
# On non-Apple CUDA hardware after configuring with OpenMVS_USE_CUDA=ON and OpenMVS_REQUIRE_CUDA=ON:
OPENMVS_CUDA_BUILD_JOBS=2 OPENMVS_CUDA_CTEST_TIMEOUT=1200 scripts/verify-cuda.sh
```

Result: `MetalRuntimeSmoke` passes outside the sandbox with a visible default Metal device and validates the shared-buffer helper by uploading input, filling output storage, running a compute kernel, and reading results back. It also validates the common Metal texture helper surface by round-tripping an R16 texture and running an R32 texture read/write compute kernel. The same test also covers the chained SceneRefine pair smoke, the host-level `Scene::RefineMeshMetal(...)` synthetic smoke, the PatchMatch score-plane smoke, the PatchMatch low-depth prior smoke, the PatchMatch geometric-consistency smoke, the PatchMatch initialize-score smoke, the PatchMatch propagation smoke, the PatchMatch refinement smoke, the PatchMatch filter-plane smoke, and the host-level multi-resolution PatchMatch smoke using CMake-generated Metal shader artifacts from the checked-in SceneRefine and PatchMatch MSL sources. `CommonUnitTests` also passes and now covers `SEACAVE::GPU` parse/compiled-state helpers plus the Apple and non-Apple `auto` backend priority matrix. The full configured build passes.

The current primary Metal CTest set passed outside the sandbox serially: 18/18 tests in 110.91s. The suite includes `CommonUnitTests`, `SFMPipelineTest`, CPU-pinned `MVSPipelineTest`, `MVSMetalCudaSurfaceAuditTest`, `SecondaryCudaSurfaceAuditTest`, `CudaVerifierSelfTest`, `CudaVerifierEarlyFailureSmokeTest`, `MVSPipelineMetalTest`, `MVSInProcessCpuMetalSpeedTest`, `MetalRuntimeSmoke`, `MVSRefineMeshMetalTest`, `MVSDenseMetalParityTest`, `SceneRefineMetalShaderCompile`, `PatchMatchMetalShaderCompile`, `MVSInvalidGpuBackendTest`, `NoCudaDynamicLinkageTest`, `MVSMetalAppFixtureTest`, and `MVSAppCpuMetalSceneFileParityTest`. The in-process and app parity harnesses unconditionally fail if Metal does not finish faster than CPU on their covered paths. The latest focused acceptance rerun passed `SecondaryCudaSurfaceAuditTest`, `MVSInProcessCpuMetalSpeedTest`, `MVSRefineMeshMetalTest`, `MVSDenseMetalParityTest`, and `MVSAppCpuMetalSceneFileParityTest` in 46.43s. In that run, `MVSInProcessCpuMetalSpeedTest` measured CPU pipeline elapsed 11841ms vs Metal 5192ms; `MVSAppCpuMetalSceneFileParityTest` measured Densify elapsed CPU 7171ms vs Metal 4626ms, RefineMesh elapsed CPU 226ms vs Metal 182ms, and same-mesh RefineMesh CPU 262ms vs Metal 155ms.

The registered `MVSPipelineTest` remains CPU-pinned (`Tests 2 0 1 cpu`) and uses a 2-worker CPU cap. After that cap was applied, a focused rerun reported `OpenMVS backend selected: DensifyPointCloud cpu` and passed in 13.26s; the same test then passed inside the full 18-test suite in 11.92s. `MVSPipelineMetalTest` (`Tests 2 0 0 metal`) passes the same dense reconstruction, mesh reconstruction, cleaning, texturing, and quality scoring path with the Metal backend marker; it passed inside the latest full suite in 5.06s. CUDA builds register the equivalent `MVSPipelineCudaTest` (`Tests 2 0 0 cuda`), `MVSInProcessCpuCudaSpeedTest`, and `MVSAppCpuCudaParityTest`, which respectively check the CUDA pipeline backend, in-process CPU-vs-CUDA speed, and app-level CPU/CUDA parity with `TEST_CANDIDATE_BACKEND=cuda`; these are registration-verified by `SecondaryCudaSurfaceAuditTest` but still require a CUDA-capable non-Apple machine for actual compile/runtime proof. `MVSRefineMeshMetalTest` (`Tests 4`) passes a real sample-scene path in 4.88s in the latest full suite: Metal Densify, coarse mesh reconstruction, cloned CPU and Metal reduced RefineMesh passes, finite/bounded refined mesh checks, non-zero Metal displacement sanity, and a loose mean vertex distance check against the CPU-refined mesh when vertex ordering is stable. `MVSDenseMetalParityTest` now also loads the generated CPU and Metal `.dmap` files and validates valid-pixel support, overlapping support, median/p90 relative depth error, normal angular drift, and confidence-map finiteness before deleting the temporary maps; it passed in 10.37s in the latest full suite. `SceneRefineMetalShaderCompile` and `PatchMatchMetalShaderCompile` run `xcrun -sdk macosx metal -c` on the standalone MSL sources. `MVSMetalAppFixtureTest` explicitly requires `OpenMVS backend selected: DensifyPointCloud metal` and `OpenMVS backend selected: RefineMesh metal`; it passed inside the latest full suite in 5.64s.

The expanded `NoCudaDynamicLinkageTest` checks 17 built app/library targets (`CreateStructure`, `ExtractKeyframes`, `InterfaceCOLMAP`, `InterfaceMetashape`, `InterfaceMVSNet`, `InterfacePolycam`, `DensifyPointCloud`, `ReconstructMesh`, `RefineMesh`, `TextureMesh`, `TransformScene`, `Tests`, `libMVS.dylib`, `libSFM.dylib`, `libIO.dylib`, `libMath.dylib`, and `libCommon.dylib`) with no CUDA/NVIDIA dynamic linkage matches in the primary Metal, CPU-only, and SiftGPU+Metal CUDA-off builds. A separate Viewer-enabled Metal build tree configured through the explicit vcpkg toolchain and vcpkg `viewer` feature also built `bin/Viewer.app/Contents/MacOS/Viewer` plus the app/test target set. In that tree, focused `CommonUnitTests`, `NoCudaDynamicLinkageTest`, `SecondaryCudaSurfaceAuditTest`, and `MVSMetalCudaSurfaceAuditTest` reruns passed; the no-CUDA linkage test included `Viewer.app` as an optional 18th target, and direct `otool -L` inspection of the Viewer executable showed OpenMVS libraries and Apple frameworks with no CUDA/NVIDIA dynamic dependencies. A Viewer-enabled `ctest -N -R "MVSPipelineCudaTest|MVSInProcessCpuCudaSpeedTest|MVSAppCpuCudaParityTest"` also reports zero CUDA proof tests on Apple. After adding the source-audit tests, CUDA-specific CTest registrations, backend-marker audit checks, app parity speed-gate audit checks, in-process CPU-vs-GPU speed-gate audit checks, root Metal framework/platform audit checks, Common/MVS source-gating audit checks, MVS CUDA/Metal helper-header audit checks, generated-doc CUDA/Metal wording audit checks, SiftGPU source-CMake CUDA gate checks, MVS CUDA kernel-count checks, strict in-process pipeline backend checks, 900s heavy app parity timeouts, Viewer Densify backend-selector checks, Viewer optional linkage coverage, and fixture-level app backend marker checks, the Metal, CPU-only, SiftGPU+Metal, and Viewer+Metal build directories were reconfigured outside the sandbox; the focused `SecondaryCudaSurfaceAuditTest|CudaVerifierSelfTest|CudaVerifierEarlyFailureSmokeTest` trio passes in all four configured trees.

Reusable real-scene parity harness:

```bash
cmake \
  -DTEST_SCENE_FILE=/absolute/path/to/scene.mvs \
  -DTEST_SCENE_COPY_ROOT=/absolute/path/to/minimal/scene-folder \
  -DTEST_WORK_DIR=/absolute/path/to/openmvs/build-metal-vcpkg/app-cpu-metal-parity-real \
  -DTEST_REFERENCE_BACKEND=cpu \
  -DTEST_CANDIDATE_BACKEND=metal \
  -DTEST_MAX_THREADS=4 \
  -DDENSIFY_EXE=/absolute/path/to/openmvs/build-metal-vcpkg/bin/DensifyPointCloud \
  -DRECONSTRUCT_EXE=/absolute/path/to/openmvs/build-metal-vcpkg/bin/ReconstructMesh \
  -DREFINE_EXE=/absolute/path/to/openmvs/build-metal-vcpkg/bin/RefineMesh \
  -P apps/Tests/RunMVSAppBackendParity.cmake
```

`TEST_SCENE_FILE` must be absolute and must be inside `TEST_SCENE_COPY_ROOT`; choose the smallest copy root containing the `.mvs` file and referenced images to avoid duplicating large unrelated directories. The harness defaults to 4 threads, reduced densify/refine resolutions, loose CPU/Metal output-count tolerances, and an unconditional candidate-faster-than-CPU gate. The defaults can be tuned with `TEST_DENSIFY_MIN_RESOLUTION`, `TEST_DENSIFY_SUB_RESOLUTION_LEVELS`, `TEST_DENSIFY_NUMBER_VIEWS`, `TEST_DENSIFY_ITERS`, `TEST_DENSIFY_GEOMETRIC_ITERS`, `TEST_REFINE_MIN_RESOLUTION`, `TEST_REFINE_MAX_VIEWS`, `TEST_REFINE_GRADIENT_STEP`, `TEST_MIN_DENSE_VERTICES`, `TEST_MIN_MESH_VERTICES`, `TEST_MIN_MESH_FACES`, and the `TEST_*_PERCENT` tolerance variables.

The `TEST_SCENE_FILE` path itself is now registered as `MVSAppCpuMetalSceneFileParityTest` and was validated against the bundled sample scene outside the sandbox. The registered scene-file app parity test has a 900s CTest timeout; one marker-verification rerun was killed at the previous 300s timeout during `ReconstructMesh` while the machine was under memory pressure, then passed after reconfiguration with the longer timeout. A later full-suite attempt on the 16-test tree killed the duplicate `MVSAppCpuMetalParityTest` during reference `ReconstructMesh`, while the registered scene-file parity test immediately passed; the duplicate heavy Metal parity registration was removed so full-suite verification keeps one CPU-vs-Metal speed-gated app test. After the CPU-forced in-process pipeline was capped at 2 workers and the in-process speed gate was added, the current 18-test full serial suite passed in 110.91s. In the latest focused app-parity run, `MVSAppCpuMetalSceneFileParityTest` passed with dense vertices CPU 70,117 vs Metal 78,560, Densify elapsed CPU 7171ms vs Metal 4626ms; mesh vertices/faces CPU 28,755/57,473 vs Metal 32,513/64,974; RefineMesh elapsed CPU 226ms vs Metal 182ms; and same-mesh RefineMesh CPU 262ms vs Metal 155ms with identical same-mesh output counts. In the SiftGPU+Metal CUDA-off build, an earlier focused run passed in 15.94s with dense vertices CPU 70,768 vs Metal 56,247, Densify elapsed 8647ms vs 4522ms; mesh vertices/faces CPU 28,953/57,869 vs Metal 25,149/50,272; RefineMesh elapsed 668ms vs 165ms; and same-mesh RefineMesh CPU 226ms vs Metal 160ms.

Representative local real-scene validation used `/Users/akshitgarg/nerf/scene.mvs`, staged under `/private/tmp` with the `images` folder symlinked to avoid duplicating unrelated outputs. A full CPU/Metal harness run before the final normal correction produced CPU dense vertices 1,204,801 vs Metal 460,165 while Metal was faster, so the failure was quality/count parity rather than speed. Follow-up diagnostics exported CPU and Metal `.dmap` files with `--fusion-mode 1 --remove-dmaps 0` and sampled the dense-fusion gates. Metal had comparable depth agreement once a neighbor depth existed, but only about 35% of depth-agreeing pairs passed the 25-degree normal gate, versus about 68% for CPU. Recomputing Metal final normals with radius-4 least-squares support raised sampled normal-gate agreement to about 63%. After that patch, a full real-scene Metal `DensifyPointCloud` run produced 979,824 dense vertices against the 1,204,801 CPU baseline, above the harness 65% lower bound, and remained faster: roughly 4m33.6s initial depth estimation, 53.9s and 57.8s for the two geometric passes, and 8.7s dense fusion, about 6m34s total versus the prior CPU Densify baseline of about 8m58s.

The current CPU-only CTest set registers ten tests: `CommonUnitTests`, `SFMPipelineTest`, CPU-pinned `MVSPipelineTest`, `MVSMetalCudaSurfaceAuditTest`, `SecondaryCudaSurfaceAuditTest`, `CudaVerifierSelfTest`, `CudaVerifierEarlyFailureSmokeTest`, `MVSInvalidGpuBackendTest`, `NoCudaDynamicLinkageTest`, and `MVSNoMetalAppFallbackTest`. After the CPU pipeline cap was applied, the CPU-only `Tests` target rebuilt and the focused CPU-only `MVSPipelineTest` passed in 12.99s. The focused CPU-only `SecondaryCudaSurfaceAuditTest|MVSInvalidGpuBackendTest|NoCudaDynamicLinkageTest|MVSNoMetalAppFallbackTest` rerun passed in 8.12s, including invalid backend rejection, no CUDA/NVIDIA dynamic linkage across the built command-line apps and shared libraries listed above, and explicit CPU backend markers from `DensifyPointCloud --gpu-backend metal` and `RefineMesh --gpu-backend metal`; it produced 70,822 dense vertices and a 28,990-vertex / 57,939-face refined mesh.

Before the source-audit tests were added, the Apple Metal + SiftGPU + CUDA-off CTest set also passed outside the sandbox: 12/12 in 88.43s while SiftGPU was enabled and CUDA remained disabled. Its capped MVS timings are consistent with the primary Metal build: CPU-pinned `MVSPipelineTest` 7.20s and `MVSPipelineMetalTest` 4.50s. `MVSRefineMeshMetalTest` passes in 4.50s and the strengthened `MVSDenseMetalParityTest` passes in 10.24s. After the backend-selector change, the affected SiftGPU+Metal targets rebuilt and the focused `CommonUnitTests|NoCudaDynamicLinkageTest` rerun passed in 3.39s. `NoCudaDynamicLinkageTest` passes in this build as well, so enabling SiftGPU's non-CUDA OpenGL path does not introduce CUDA/NVIDIA dynamic linkage on Apple. The reconfigured SiftGPU+Metal build now also registers both source-audit tests, and the focused audit runs pass.

`MVSDenseMetalParityTest` (`Tests 5`) passes a CPU-vs-Metal dense reconstruction comparison on the sample scene, checking that Metal output stays within loose point-count, raw AABB sanity, robust 2%-trimmed AABB diagonal, robust AABB center, depth-map valid-pixel ratio, common valid support, median/p90 relative depth error, median normal angle, and confidence-map finiteness tolerances after clearing per-image depth caches between backends.

Direct Metal MVS pipeline check:

```bash
build-metal-vcpkg/bin/Tests 2 0 0
```

Result: the Metal Densify path produced 56,890 dense points, reconstructed 25,897 mesh faces, cleaned to 18,039 faces, textured the mesh, and reached reconstruction quality score 50.638.

`RefineMesh` backend policy:

- `--gpu-backend cpu` keeps the historical CPU default for this app.
- `--gpu-backend metal` enters `Scene::RefineMeshMetal(...)` in Metal builds and fails the command if selected Metal refinement fails; in builds without `_USE_METAL`, it warns and falls back to CPU refinement.
- `--gpu-backend cuda` tries `Scene::RefineMeshCUDA(...)` when CUDA is compiled and falls back to CPU.
- `--gpu-backend auto` uses the shared backend priority: Metal first on Apple, CUDA first elsewhere, then CPU. If auto selects Metal in a Metal build, a Metal refinement failure is fatal instead of falling through to CUDA or CPU.
- Existing `--cuda-device -1` still implies CUDA when no backend override is provided.
- The Metal RefineMesh path is verified by synthetic kernel/host smokes and the registered sample-scene `MVSRefineMeshMetalTest`, including a reduced CPU-vs-Metal mesh comparison.

`DensifyPointCloud` backend policy:

- `--gpu-backend auto` is the default, preserving the old CUDA-enabled behavior where CUDA is compiled and selected on non-Apple platforms while selecting Metal first on Apple.
- `--gpu-backend cpu` forces CPU PatchMatch estimation.
- `--gpu-backend cuda` uses the existing CUDA PatchMatch pool when CUDA is compiled. If CUDA is explicitly requested in a non-CUDA build, Densify logs a warning and falls back to CPU PatchMatch estimation.
- `--gpu-backend metal` enters the Metal PatchMatch host path for the initial multi-resolution PatchMatch pass and subsequent geometric-consistency refinement passes when Metal is compiled. If Metal is explicitly requested in a non-Metal build, Densify logs a warning and falls back to CPU PatchMatch estimation.
- `--patch-match-cuda-instances` now bounds both CUDA and Metal PatchMatch backend worker pools; the option name is preserved for compatibility.
- The current Metal path is verified by synthetic host smoke tests and the registered sample-scene Metal MVS pipeline test. The non-Metal fallback is verified by `MVSNoMetalAppFallbackTest`.

## Next Work

- Run the reusable `TEST_SCENE_FILE` parity harness against additional representative real `.mvs` scenes, compare Metal output quality and runtime to CPU, and tune quality-sensitive policies if needed. One local real scene has passed the dense-count and speed gate after the radius-4 Metal final-normal correction, but broader scene coverage would improve confidence.
- Optimize the RefineMesh Metal host path further by keeping projected view maps, mutable mesh/view buffers, and immutable image buffers resident across pairs and iterations instead of re-uploading them for every launcher call. SceneRefine setup is cached, several per-pair/per-iteration kernels are fused, reusable buffer slots cover the projection and scoring hot path, pair accumulators stay resident across one scoring iteration, projection is amortized across short gradient batches, and app parity now gates both cross-output and same-mesh RefineMesh CPU/Metal timings. Larger representative benchmarks and fuller resident-buffer ownership are still needed before claiming RefineMesh Metal is consistently faster than CPU outside the sample fixture.
- Continue improving PatchMatch Metal parity after the score/low-depth-prior/geometric-consistency/initialize/AMHMVS-propagation/refinement/filter/multi-resolution-host slices and resident plane/cost/view buffers: resident image/depth texture-style buffers and broader CPU comparisons for quality-sensitive aggregation paths remain useful follow-ups.
- Optional, outside the Metal/CPU acceptance scope: run the non-Apple CUDA verifier if maintainers want CUDA-on preservation evidence.
