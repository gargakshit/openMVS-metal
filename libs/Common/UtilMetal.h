////////////////////////////////////////////////////////////////////
// UtilMetal.h
//
// Copyright 2007 cDc@seacave
// Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
// Codex sign-off: OpenAI Codex assisted with this file.
// Distributed under the Boost Software License, Version 1.0
// (See http://www.boost.org/LICENSE_1_0.txt)

#ifndef  __SEACAVE_METAL_H__
#define  __SEACAVE_METAL_H__


// I N C L U D E S /////////////////////////////////////////////////

#include "Config.h"

#ifdef _USE_METAL

#include <cstddef>
#include <cstdint>
#include <string>


// D E F I N E S ///////////////////////////////////////////////////


// S T R U C T S ///////////////////////////////////////////////////

namespace SEACAVE {

namespace METAL {

enum class PixelFormat {
	R32Float,
	R16Float
};

struct Device {
	std::string name;
	bool lowPower = false;
	bool headless = false;
};

// returns true if a default Metal device can be created
GENERAL_API bool isAvailable();

// fills basic information for the default Metal device
GENERAL_API bool getDefaultDevice(Device& device);

class GENERAL_API Buffer
{
protected:
	void* pBuffer;
	size_t nSize;

public:
	Buffer();
	explicit Buffer(size_t size);
	Buffer(const void* pDataHost, size_t size);
	~Buffer();

	Buffer(const Buffer&) = delete;
	Buffer& operator=(const Buffer&) = delete;
	Buffer(Buffer&& rhs) noexcept;
	Buffer& operator=(Buffer&& rhs) noexcept;

	bool IsValid() const { return pBuffer != NULL; }
	size_t Size() const { return nSize; }
	void Release();
	bool Reset(size_t size, std::string* error = NULL);
	bool Reset(const void* pDataHost, size_t size, std::string* error = NULL);
	bool SetData(const void* pDataHost, size_t size, std::string* error = NULL);
	bool GetData(void* pDataHost, size_t size, std::string* error = NULL) const;
	bool Fill(uint8_t value, std::string* error = NULL);

	void* NativeHandle() const { return pBuffer; }
};

class GENERAL_API Texture2D
{
protected:
	void* pTexture;
	size_t nWidth;
	size_t nHeight;
	PixelFormat format;

public:
	Texture2D();
	Texture2D(size_t width, size_t height, PixelFormat fmt);
	Texture2D(const void* pDataHost, size_t width, size_t height, PixelFormat fmt);
	~Texture2D();

	Texture2D(const Texture2D&) = delete;
	Texture2D& operator=(const Texture2D&) = delete;
	Texture2D(Texture2D&& rhs) noexcept;
	Texture2D& operator=(Texture2D&& rhs) noexcept;

	bool IsValid() const { return pTexture != NULL; }
	size_t Width() const { return nWidth; }
	size_t Height() const { return nHeight; }
	PixelFormat Format() const { return format; }
	size_t BytesPerPixel() const;
	size_t BytesPerRow() const { return nWidth*BytesPerPixel(); }
	size_t BytesSize() const { return BytesPerRow()*nHeight; }
	void Release();
	bool Reset(size_t width, size_t height, PixelFormat fmt, std::string* error = NULL);
	bool Reset(const void* pDataHost, size_t width, size_t height, PixelFormat fmt, std::string* error = NULL);
	bool SetData(const void* pDataHost, size_t size, std::string* error = NULL);
	bool GetData(void* pDataHost, size_t size, std::string* error = NULL) const;

	void* NativeHandle() const { return pTexture; }
};

// allocates shared buffers/textures, compiles trivial compute kernels, runs
// them, and validates readback. Returns false and fills error on any Metal failure.
GENERAL_API bool RunSmokeTest(std::string* error = NULL);

} // namespace METAL

} // namespace SEACAVE

#endif // _USE_METAL

#endif // __SEACAVE_METAL_H__
