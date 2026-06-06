/*
* Camera.h
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

#ifndef _MVS_METAL_CAMERA_H_
#define _MVS_METAL_CAMERA_H_


// I N C L U D E S /////////////////////////////////////////////////

#include "Maths.h"


// S T R U C T S ///////////////////////////////////////////////////

namespace MVS {

namespace METAL {

struct LinearCameraModel {
	Point2 f;
	Point2 p;
};

struct Pose {
	Matrix3 R;
	Point3 C;
};

struct Camera {
	LinearCameraModel model;
	Pose pose;
	Point2i size;
};

#ifdef __METAL_VERSION__
inline metal::float2 TransformPointC2I(const LinearCameraModel model, const metal::float3 X)
{
	const metal::float2 f = Load(model.f);
	const metal::float2 p = Load(model.p);
	return metal::float2(
		f.x * X.x / X.z + p.x,
		f.y * X.y / X.z + p.y);
}

inline metal::float3 TransformPointI2C(const LinearCameraModel model, const metal::float2 x, const float depth)
{
	const metal::float2 f = Load(model.f);
	const metal::float2 p = Load(model.p);
	return metal::float3(
		depth * (x.x - p.x) / f.x,
		depth * (x.y - p.y) / f.y,
		depth);
}

inline metal::float3 TransformPointW2C(const Pose pose, const metal::float3 X)
{
	return Mul(pose.R, X - Load(pose.C));
}

inline metal::float3 TransformPointC2W(const Pose pose, const metal::float3 X)
{
	return MulTranspose(pose.R, X) + Load(pose.C);
}

inline metal::float2 TransformPointW2I(const Camera camera, const metal::float3 X)
{
	return TransformPointC2I(camera.model, TransformPointW2C(camera.pose, X));
}

inline metal::float3 TransformPointI2W(const Camera camera, const metal::float2 x, const float depth)
{
	return TransformPointC2W(camera.pose, TransformPointI2C(camera.model, x, depth));
}
#else
static_assert(sizeof(LinearCameraModel) == sizeof(float)*4, "Metal LinearCameraModel must stay packed");
static_assert(sizeof(Pose) == sizeof(float)*12, "Metal Pose must stay packed");
static_assert(sizeof(Camera) == sizeof(float)*16 + sizeof(int32_t)*2, "Metal Camera must stay packed");
#endif

} // namespace METAL

} // namespace MVS

#endif // _MVS_METAL_CAMERA_H_
