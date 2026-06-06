////////////////////////////////////////////////////////////////////
// UtilGPU.cpp
//
// Copyright 2007 cDc@seacave
// Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
// Codex sign-off: OpenAI Codex assisted with this file.
// Distributed under the Boost Software License, Version 1.0
// (See http://www.boost.org/LICENSE_1_0.txt)

#include "UtilGPU.h"

#include <algorithm>
#include <cctype>


// D E F I N E S ///////////////////////////////////////////////////


namespace SEACAVE {

namespace GPU {

// S T R U C T S ///////////////////////////////////////////////////

GENERAL_API std::string desiredBackend("auto");
static Backend lastSelectedBackend = Backend::UNKNOWN;

Backend ParseBackend(const std::string& backend)
{
	std::string lower(backend);
	std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return (char)std::tolower(c); });
	if (lower.empty() || lower == "auto")
		return Backend::AUTO;
	if (lower == "cpu" || lower == "none" || lower == "off")
		return Backend::CPU;
	if (lower == "cuda")
		return Backend::CUDA;
	if (lower == "metal")
		return Backend::METAL;
	return Backend::UNKNOWN;
}

const char* ToString(Backend backend)
{
	switch (backend) {
	case Backend::AUTO:
		return "auto";
	case Backend::CPU:
		return "cpu";
	case Backend::CUDA:
		return "cuda";
	case Backend::METAL:
		return "metal";
	default:
		return "unknown";
	}
}

bool IsCompiled(Backend backend)
{
	switch (backend) {
	case Backend::AUTO:
		return true;
	case Backend::CPU:
		return true;
	case Backend::CUDA:
		#ifdef _USE_CUDA
		return true;
		#else
		return false;
		#endif
	case Backend::METAL:
		#ifdef _USE_METAL
		return true;
		#else
		return false;
		#endif
	default:
		return false;
	}
}

Backend SelectAutoBackend(bool cudaCompiled, bool metalCompiled, bool applePlatform)
{
	if (applePlatform) {
		if (metalCompiled)
			return Backend::METAL;
		if (cudaCompiled)
			return Backend::CUDA;
	} else {
		if (cudaCompiled)
			return Backend::CUDA;
		if (metalCompiled)
			return Backend::METAL;
	}
	return Backend::CPU;
}

Backend AutoBackend()
{
	#ifdef __APPLE__
	const bool applePlatform(true);
	#else
	const bool applePlatform(false);
	#endif
	return SelectAutoBackend(IsCompiled(Backend::CUDA), IsCompiled(Backend::METAL), applePlatform);
}

Backend ResolveBackend(Backend backend)
{
	return backend == Backend::AUTO ? AutoBackend() : backend;
}

void ResetLastSelectedBackend()
{
	lastSelectedBackend = Backend::UNKNOWN;
}

void SetLastSelectedBackend(Backend backend)
{
	lastSelectedBackend = backend;
}

Backend LastSelectedBackend()
{
	return lastSelectedBackend;
}

/*----------------------------------------------------------------*/

} // namespace GPU

} // namespace SEACAVE
