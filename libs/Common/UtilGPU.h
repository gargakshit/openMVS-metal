////////////////////////////////////////////////////////////////////
// UtilGPU.h
//
// Copyright 2007 cDc@seacave
// Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
// Codex sign-off: OpenAI Codex assisted with this file.
// Distributed under the Boost Software License, Version 1.0
// (See http://www.boost.org/LICENSE_1_0.txt)

#ifndef  __SEACAVE_GPU_H__
#define  __SEACAVE_GPU_H__


// I N C L U D E S /////////////////////////////////////////////////

#include "Config.h"

#include <string>


// D E F I N E S ///////////////////////////////////////////////////


// S T R U C T S ///////////////////////////////////////////////////

namespace SEACAVE {

namespace GPU {

enum class Backend {
	AUTO,
	CPU,
	CUDA,
	METAL,
	UNKNOWN
};

extern GENERAL_API std::string desiredBackend;

GENERAL_API Backend ParseBackend(const std::string& backend);
GENERAL_API const char* ToString(Backend backend);
GENERAL_API bool IsCompiled(Backend backend);
GENERAL_API Backend SelectAutoBackend(bool cudaCompiled, bool metalCompiled, bool applePlatform);
GENERAL_API Backend AutoBackend();
GENERAL_API Backend ResolveBackend(Backend backend);
GENERAL_API void ResetLastSelectedBackend();
GENERAL_API void SetLastSelectedBackend(Backend backend);
GENERAL_API Backend LastSelectedBackend();

} // namespace GPU

} // namespace SEACAVE

#endif // __SEACAVE_GPU_H__
