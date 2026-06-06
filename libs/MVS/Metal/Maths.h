/*
* Maths.h
*
* Copyright (c) 2014-2026 SEACAVE
* Copyright (c) 2026-present Akshit Garg <git+openmvs-metal@akshit.network>
* Codex sign-off: OpenAI Codex assisted with this file.
*
* Author(s):
*
*      cDc <cdc.seacave@gmail.com>
*      Akshit Garg <git+openmvs-metal@akshit.network>
*
*
* This program is free software: you can redistribute it and/or modify
* it under the terms of the GNU Affero General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* This program is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU Affero General Public License for more details.
*
* You should have received a copy of the GNU Affero General Public License
* along with this program.  If not, see <http://www.gnu.org/licenses/>.
*
*
* Additional Terms:
*
*      You are required to preserve legal notices and author attributions in
*      that material or in the Appropriate Legal Notices displayed by works
*      containing it.
*/

#pragma once

#ifndef _MVS_METAL_MATHS_H_
#define _MVS_METAL_MATHS_H_


// I N C L U D E S /////////////////////////////////////////////////

#ifdef __METAL_VERSION__
#include <metal_stdlib>
#else
#include <cstdint>
#endif


// S T R U C T S ///////////////////////////////////////////////////

namespace MVS {

namespace METAL {

#ifdef __METAL_VERSION__
using Point2 = metal::packed_float2;
using Point3 = metal::packed_float3;
using Point4 = metal::packed_float4;
using Point2i = metal::packed_int2;
using Point3u = metal::packed_uint3;

struct Matrix3 {
	float m[9];
};

inline metal::float2 Load(const Point2 p)
{
	return metal::float2(p[0], p[1]);
}

inline metal::float3 Load(const Point3 p)
{
	return metal::float3(p[0], p[1], p[2]);
}

inline metal::float4 Load(const Point4 p)
{
	return metal::float4(p[0], p[1], p[2], p[3]);
}

inline metal::int2 Load(const Point2i p)
{
	return metal::int2(p[0], p[1]);
}

inline metal::uint3 Load(const Point3u p)
{
	return metal::uint3(p[0], p[1], p[2]);
}

inline Point2 StorePoint2(const metal::float2 p)
{
	return Point2(p.x, p.y);
}

inline Point3 StorePoint3(const metal::float3 p)
{
	return Point3(p.x, p.y, p.z);
}

inline Point4 StorePoint4(const metal::float4 p)
{
	return Point4(p.x, p.y, p.z, p.w);
}

inline metal::float3 Mul(const Matrix3 M, const metal::float3 v)
{
	return metal::float3(
		M.m[0] * v.x + M.m[1] * v.y + M.m[2] * v.z,
		M.m[3] * v.x + M.m[4] * v.y + M.m[5] * v.z,
		M.m[6] * v.x + M.m[7] * v.y + M.m[8] * v.z);
}

inline metal::float3 MulTranspose(const Matrix3 M, const metal::float3 v)
{
	return metal::float3(
		M.m[0] * v.x + M.m[3] * v.y + M.m[6] * v.z,
		M.m[1] * v.x + M.m[4] * v.y + M.m[7] * v.z,
		M.m[2] * v.x + M.m[5] * v.y + M.m[8] * v.z);
}
#else
struct Point2 {
	float x, y;
};

struct Point3 {
	float x, y, z;
};

struct Point4 {
	float x, y, z, w;
};

struct Point2i {
	int32_t x, y;
};

struct Point3u {
	uint32_t x, y, z;
};

struct Matrix3 {
	float m[9];
};

static_assert(sizeof(Point2) == sizeof(float)*2, "Metal Point2 must match packed host Point2f layout");
static_assert(sizeof(Point3) == sizeof(float)*3, "Metal Point3 must match packed host Point3f layout");
static_assert(sizeof(Point4) == sizeof(float)*4, "Metal Point4 must match packed host depth-normal layout");
static_assert(sizeof(Point2i) == sizeof(int32_t)*2, "Metal Point2i must match packed host Point2i layout");
static_assert(sizeof(Point3u) == sizeof(uint32_t)*3, "Metal Point3u must match packed host face layout");
static_assert(sizeof(Matrix3) == sizeof(float)*9, "Metal Matrix3 must match packed host Matrix3 layout");
#endif

} // namespace METAL

} // namespace MVS

#endif // _MVS_METAL_MATHS_H_
