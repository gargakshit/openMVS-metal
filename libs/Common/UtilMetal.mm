////////////////////////////////////////////////////////////////////
// UtilMetal.mm
//
// Copyright 2007 cDc@seacave
// Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
// Codex sign-off: OpenAI Codex assisted with this file.
// Distributed under the Boost Software License, Version 1.0
// (See http://www.boost.org/LICENSE_1_0.txt)

#include "UtilMetal.h"

#ifdef _USE_METAL

@import Foundation;
@import Metal;

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>


// D E F I N E S ///////////////////////////////////////////////////


namespace SEACAVE {

namespace METAL {

// S T R U C T S ///////////////////////////////////////////////////

static std::string ToString(NSString* str)
{
	return str != nil ? std::string([str UTF8String]) : std::string();
}

static void SetError(std::string* error, NSString* message)
{
	if (error != NULL)
		*error = ToString(message);
}

static void SetError(std::string* error, NSError* nsError, const char* fallback)
{
	if (error == NULL)
		return;
	if (nsError != nil && [nsError localizedDescription] != nil)
		*error = ToString([nsError localizedDescription]);
	else
		*error = fallback;
}

static id<MTLBuffer> GetNativeBuffer(const Buffer& buffer)
{
	return (__bridge id<MTLBuffer>)buffer.NativeHandle();
}

static id<MTLTexture> GetNativeTexture(const Texture2D& texture)
{
	return (__bridge id<MTLTexture>)texture.NativeHandle();
}

static MTLPixelFormat ToMetalPixelFormat(PixelFormat format)
{
	switch (format) {
	case PixelFormat::R32Float:
		return MTLPixelFormatR32Float;
	case PixelFormat::R16Float:
		return MTLPixelFormatR16Float;
	}
	return MTLPixelFormatInvalid;
}

static size_t BytesPerPixel(PixelFormat format)
{
	switch (format) {
	case PixelFormat::R32Float:
		return sizeof(float);
	case PixelFormat::R16Float:
		return sizeof(uint16_t);
	}
	return 0;
}

Buffer::Buffer()
	:
	pBuffer(NULL),
	nSize(0)
{
}

Buffer::Buffer(size_t size)
	:
	pBuffer(NULL),
	nSize(0)
{
	Reset(size, NULL);
}

Buffer::Buffer(const void* pDataHost, size_t size)
	:
	pBuffer(NULL),
	nSize(0)
{
	Reset(pDataHost, size, NULL);
}

Buffer::~Buffer()
{
	Release();
}

Buffer::Buffer(Buffer&& rhs) noexcept
	:
	pBuffer(rhs.pBuffer),
	nSize(rhs.nSize)
{
	rhs.pBuffer = NULL;
	rhs.nSize = 0;
}

Buffer& Buffer::operator=(Buffer&& rhs) noexcept
{
	if (this != &rhs) {
		Release();
		pBuffer = rhs.pBuffer;
		nSize = rhs.nSize;
		rhs.pBuffer = NULL;
		rhs.nSize = 0;
	}
	return *this;
}

void Buffer::Release()
{
	if (pBuffer == NULL)
		return;
	id<MTLBuffer> buffer = (__bridge id<MTLBuffer>)pBuffer;
	#if __has_feature(objc_arc)
	CFRelease(pBuffer);
	#else
	[buffer release];
	#endif
	pBuffer = NULL;
	nSize = 0;
}

bool Buffer::Reset(size_t size, std::string* error)
{
	Release();
	if (size == 0) {
		SetError(error, @"cannot allocate an empty Metal buffer");
		return false;
	}
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		id<MTLBuffer> buffer = [device newBufferWithLength:size options:MTLResourceStorageModeShared];
		if (buffer == nil) {
			SetError(error, @"failed to allocate Metal buffer");
			return false;
		}
		#if __has_feature(objc_arc)
		pBuffer = (__bridge_retained void*)buffer;
		#else
		pBuffer = buffer;
		#endif
		nSize = size;
		return true;
	}
}

bool Buffer::Reset(const void* pDataHost, size_t size, std::string* error)
{
	if (!Reset(size, error))
		return false;
	return SetData(pDataHost, size, error);
}

bool Buffer::SetData(const void* pDataHost, size_t size, std::string* error)
{
	if (pDataHost == NULL) {
		SetError(error, @"cannot upload null data to a Metal buffer");
		return false;
	}
	if (pBuffer == NULL || size > nSize) {
		SetError(error, @"Metal buffer upload exceeds allocation");
		return false;
	}
	id<MTLBuffer> buffer = GetNativeBuffer(*this);
	std::memcpy([buffer contents], pDataHost, size);
	return true;
}

bool Buffer::GetData(void* pDataHost, size_t size, std::string* error) const
{
	if (pDataHost == NULL) {
		SetError(error, @"cannot download Metal buffer data to null host memory");
		return false;
	}
	if (pBuffer == NULL || size > nSize) {
		SetError(error, @"Metal buffer download exceeds allocation");
		return false;
	}
	id<MTLBuffer> buffer = GetNativeBuffer(*this);
	std::memcpy(pDataHost, [buffer contents], size);
	return true;
}

bool Buffer::Fill(uint8_t value, std::string* error)
{
	if (pBuffer == NULL) {
		SetError(error, @"cannot fill an invalid Metal buffer");
		return false;
	}
	id<MTLBuffer> buffer = GetNativeBuffer(*this);
	std::memset([buffer contents], value, nSize);
	return true;
}

Texture2D::Texture2D()
	:
	pTexture(NULL),
	nWidth(0),
	nHeight(0),
	format(PixelFormat::R32Float)
{
}

Texture2D::Texture2D(size_t width, size_t height, PixelFormat fmt)
	:
	pTexture(NULL),
	nWidth(0),
	nHeight(0),
	format(fmt)
{
	Reset(width, height, fmt, NULL);
}

Texture2D::Texture2D(const void* pDataHost, size_t width, size_t height, PixelFormat fmt)
	:
	pTexture(NULL),
	nWidth(0),
	nHeight(0),
	format(fmt)
{
	Reset(pDataHost, width, height, fmt, NULL);
}

Texture2D::~Texture2D()
{
	Release();
}

Texture2D::Texture2D(Texture2D&& rhs) noexcept
	:
	pTexture(rhs.pTexture),
	nWidth(rhs.nWidth),
	nHeight(rhs.nHeight),
	format(rhs.format)
{
	rhs.pTexture = NULL;
	rhs.nWidth = 0;
	rhs.nHeight = 0;
	rhs.format = PixelFormat::R32Float;
}

Texture2D& Texture2D::operator=(Texture2D&& rhs) noexcept
{
	if (this != &rhs) {
		Release();
		pTexture = rhs.pTexture;
		nWidth = rhs.nWidth;
		nHeight = rhs.nHeight;
		format = rhs.format;
		rhs.pTexture = NULL;
		rhs.nWidth = 0;
		rhs.nHeight = 0;
		rhs.format = PixelFormat::R32Float;
	}
	return *this;
}

size_t Texture2D::BytesPerPixel() const
{
	return METAL::BytesPerPixel(format);
}

void Texture2D::Release()
{
	if (pTexture == NULL)
		return;
	id<MTLTexture> texture = (__bridge id<MTLTexture>)pTexture;
	#if __has_feature(objc_arc)
	CFRelease(pTexture);
	#else
	[texture release];
	#endif
	pTexture = NULL;
	nWidth = 0;
	nHeight = 0;
	format = PixelFormat::R32Float;
}

bool Texture2D::Reset(size_t width, size_t height, PixelFormat fmt, std::string* error)
{
	Release();
	if (width == 0 || height == 0) {
		SetError(error, @"cannot allocate an empty Metal texture");
		return false;
	}
	const size_t bytesPerPixel = METAL::BytesPerPixel(fmt);
	const MTLPixelFormat metalFormat = ToMetalPixelFormat(fmt);
	if (bytesPerPixel == 0 || metalFormat == MTLPixelFormatInvalid) {
		SetError(error, @"unsupported Metal texture format");
		return false;
	}
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}
		MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:metalFormat
			width:(NSUInteger)width height:(NSUInteger)height mipmapped:NO];
		desc.storageMode = MTLStorageModeShared;
		desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
		id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
		if (texture == nil) {
			SetError(error, @"failed to allocate Metal texture");
			return false;
		}
		#if __has_feature(objc_arc)
		pTexture = (__bridge_retained void*)texture;
		#else
		pTexture = texture;
		#endif
		nWidth = width;
		nHeight = height;
		format = fmt;
		return true;
	}
}

bool Texture2D::Reset(const void* pDataHost, size_t width, size_t height, PixelFormat fmt, std::string* error)
{
	if (!Reset(width, height, fmt, error))
		return false;
	return SetData(pDataHost, BytesSize(), error);
}

bool Texture2D::SetData(const void* pDataHost, size_t size, std::string* error)
{
	if (pDataHost == NULL) {
		SetError(error, @"cannot upload null data to a Metal texture");
		return false;
	}
	if (pTexture == NULL || size != BytesSize()) {
		SetError(error, @"Metal texture upload size mismatch");
		return false;
	}
	id<MTLTexture> texture = GetNativeTexture(*this);
	MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)nWidth, (NSUInteger)nHeight);
	[texture replaceRegion:region mipmapLevel:0 withBytes:pDataHost bytesPerRow:BytesPerRow()];
	return true;
}

bool Texture2D::GetData(void* pDataHost, size_t size, std::string* error) const
{
	if (pDataHost == NULL) {
		SetError(error, @"cannot download Metal texture data to null host memory");
		return false;
	}
	if (pTexture == NULL || size != BytesSize()) {
		SetError(error, @"Metal texture download size mismatch");
		return false;
	}
	id<MTLTexture> texture = GetNativeTexture(*this);
	MTLRegion region = MTLRegionMake2D(0, 0, (NSUInteger)nWidth, (NSUInteger)nHeight);
	[texture getBytes:pDataHost bytesPerRow:BytesPerRow() fromRegion:region mipmapLevel:0];
	return true;
}

bool isAvailable()
{
	@autoreleasepool {
		return MTLCreateSystemDefaultDevice() != nil;
	}
}

bool getDefaultDevice(Device& device)
{
	@autoreleasepool {
		id<MTLDevice> metalDevice = MTLCreateSystemDefaultDevice();
		if (metalDevice == nil)
			return false;
		device.name = ToString([metalDevice name]);
		device.lowPower = [metalDevice isLowPower];
		device.headless = [metalDevice isHeadless];
		return true;
	}
}

bool RunSmokeTest(std::string* error)
{
	@autoreleasepool {
		id<MTLDevice> device = MTLCreateSystemDefaultDevice();
		if (device == nil) {
			SetError(error, @"no default Metal device");
			return false;
		}

		static NSString* const source =
			@"#include <metal_stdlib>\n"
			 "using namespace metal;\n"
			 "kernel void add_one(device const uint* input [[buffer(0)]],\n"
			 "                    device uint* output [[buffer(1)]],\n"
			 "                    uint gid [[thread_position_in_grid]]) {\n"
			 "    output[gid] = input[gid] + 1u;\n"
			 "}\n"
			 "kernel void texture_add(texture2d<float, access::read> input [[texture(0)]],\n"
			 "                        texture2d<float, access::write> output [[texture(1)]],\n"
			 "                        uint2 gid [[thread_position_in_grid]]) {\n"
			 "    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;\n"
			 "    output.write(float4(input.read(gid).r + 2.0f, 0.0f, 0.0f, 1.0f), gid);\n"
			 "}\n";

		NSError* nsError = nil;
		id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&nsError];
		if (library == nil) {
			SetError(error, nsError, "failed to compile Metal smoke library");
			return false;
		}
		id<MTLFunction> function = [library newFunctionWithName:@"add_one"];
		if (function == nil) {
			SetError(error, @"failed to load Metal smoke function");
			return false;
		}
		id<MTLFunction> textureFunction = [library newFunctionWithName:@"texture_add"];
		if (textureFunction == nil) {
			SetError(error, @"failed to load Metal texture smoke function");
			return false;
		}
		id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&nsError];
		if (pipeline == nil) {
			SetError(error, nsError, "failed to create Metal smoke pipeline");
			return false;
		}
		id<MTLComputePipelineState> texturePipeline = [device newComputePipelineStateWithFunction:textureFunction error:&nsError];
		if (texturePipeline == nil) {
			SetError(error, nsError, "failed to create Metal texture smoke pipeline");
			return false;
		}
		id<MTLCommandQueue> queue = [device newCommandQueue];
		if (queue == nil) {
			SetError(error, @"failed to create Metal command queue");
			return false;
		}

		static constexpr NSUInteger numValues = 16;
		uint32_t input[numValues];
		for (NSUInteger i = 0; i < numValues; ++i)
			input[i] = (uint32_t)(i * 3u + 7u);
		Buffer inputBuffer(input, sizeof(input));
		Buffer outputBuffer(sizeof(input));
		if (!inputBuffer.IsValid() || !outputBuffer.IsValid()) {
			SetError(error, @"failed to allocate Metal smoke buffers through runtime helper");
			return false;
		}
		if (!outputBuffer.Fill(0, error))
			return false;

		static constexpr NSUInteger textureWidth = 4;
		static constexpr NSUInteger textureHeight = 3;
		float textureInput[textureWidth*textureHeight];
		for (NSUInteger i = 0; i < textureWidth*textureHeight; ++i)
			textureInput[i] = (float)i * 0.25f + 1.f;
		Texture2D inputTexture(textureInput, textureWidth, textureHeight, PixelFormat::R32Float);
		Texture2D outputTexture(textureWidth, textureHeight, PixelFormat::R32Float);
		if (!inputTexture.IsValid() || !outputTexture.IsValid()) {
			SetError(error, @"failed to allocate Metal smoke textures through runtime helper");
			return false;
		}

		uint16_t texture16Input[textureWidth*textureHeight];
		for (NSUInteger i = 0; i < textureWidth*textureHeight; ++i)
			texture16Input[i] = (uint16_t)(0x3C00u + i);
		Texture2D texture16(texture16Input, textureWidth, textureHeight, PixelFormat::R16Float);
		uint16_t texture16Output[textureWidth*textureHeight];
		if (!texture16.IsValid() || !texture16.GetData(texture16Output, sizeof(texture16Output), error)) {
			SetError(error, @"failed to roundtrip Metal R16 texture through runtime helper");
			return false;
		}
		for (NSUInteger i = 0; i < textureWidth*textureHeight; ++i) {
			if (texture16Output[i] != texture16Input[i]) {
				if (error != NULL) {
					char message[128];
					std::snprintf(message, sizeof(message),
						"Metal R16 texture readback mismatch at %u: expected %u, got %u",
						(unsigned)i, texture16Input[i], texture16Output[i]);
					*error = message;
				}
				return false;
			}
		}

		id<MTLCommandBuffer> commandBuffer = [queue commandBuffer];
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];
		if (commandBuffer == nil || encoder == nil) {
			SetError(error, @"failed to create Metal smoke command encoder");
			return false;
		}
		[encoder setComputePipelineState:pipeline];
		[encoder setBuffer:GetNativeBuffer(inputBuffer) offset:0 atIndex:0];
		[encoder setBuffer:GetNativeBuffer(outputBuffer) offset:0 atIndex:1];
		const NSUInteger threadGroupWidth = std::min<NSUInteger>(numValues, [pipeline maxTotalThreadsPerThreadgroup]);
		[encoder dispatchThreads:MTLSizeMake(numValues, 1, 1) threadsPerThreadgroup:MTLSizeMake(threadGroupWidth, 1, 1)];
		[encoder setComputePipelineState:texturePipeline];
		[encoder setTexture:GetNativeTexture(inputTexture) atIndex:0];
		[encoder setTexture:GetNativeTexture(outputTexture) atIndex:1];
		const NSUInteger textureThreadGroupWidth = std::min<NSUInteger>(textureWidth, [texturePipeline maxTotalThreadsPerThreadgroup]);
		[encoder dispatchThreads:MTLSizeMake(textureWidth, textureHeight, 1) threadsPerThreadgroup:MTLSizeMake(textureThreadGroupWidth, 1, 1)];
		[encoder endEncoding];
		[commandBuffer commit];
		[commandBuffer waitUntilCompleted];
		if ([commandBuffer status] != MTLCommandBufferStatusCompleted) {
			SetError(error, [commandBuffer error], "Metal smoke command buffer failed");
			return false;
		}

		uint32_t output[numValues];
		if (!outputBuffer.GetData(output, sizeof(output), error))
			return false;
		for (NSUInteger i = 0; i < numValues; ++i) {
			if (output[i] != input[i]+1u) {
				if (error != NULL) {
					char message[128];
					std::snprintf(message, sizeof(message),
						"Metal smoke readback mismatch at %u: expected %u, got %u",
						(unsigned)i, input[i]+1u, output[i]);
					*error = message;
				}
				return false;
			}
		}
		float textureOutput[textureWidth*textureHeight];
		if (!outputTexture.GetData(textureOutput, sizeof(textureOutput), error))
			return false;
		for (NSUInteger i = 0; i < textureWidth*textureHeight; ++i) {
			const float expected = textureInput[i] + 2.f;
			if (std::abs(textureOutput[i] - expected) > 1e-6f) {
				if (error != NULL) {
					char message[128];
					std::snprintf(message, sizeof(message),
						"Metal texture smoke readback mismatch at %u: expected %.6f, got %.6f",
						(unsigned)i, expected, textureOutput[i]);
					*error = message;
				}
				return false;
			}
		}
		return true;
	}
}

/*----------------------------------------------------------------*/

} // namespace METAL

} // namespace SEACAVE

#endif // _USE_METAL
