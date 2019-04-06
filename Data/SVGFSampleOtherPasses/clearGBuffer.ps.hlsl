/**********************************************************************************************************************
# Copyright (c) 2018, NVIDIA CORPORATION. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification, are permitted provided that the
# following conditions are met:
#  * Redistributions of code must retain the copyright notice, this list of conditions and the following disclaimer.
#  * Neither the name of NVIDIA CORPORATION nor the names of its contributors may be used to endorse or promote products
#    derived from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT
# SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
# OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
**********************************************************************************************************************/

// Falcor / Slang imports to include shared code and data structures
__import Shading;           // Imports ShaderCommon and DefaultVS, plus material evaluation

// Input texture that needs to be set by the C++ code 
Texture2D<float4> gEnvMap;

// What's in our output G-buffer structure?  This is extremely fat and probably could be cut down, except
//    our research / prototype SVGF filter and simple path tracer uses a bunch of these outputs as full
//    floats.  There's serious room here for G-buffer compression.
struct GBuffer
{
	float4 wsPos       : SV_Target0;   // World space position.  .w component = 0 if a background pixel
	float4 wsNorm      : SV_Target1;   // World space normal.  (.w is distance from camera to hit point; this may not be used)
	float4 matDif      : SV_Target2;   // .rgb diffuse material color, .a pixel opacity/transparency
	float4 matSpec     : SV_Target3;   // .rgb Falcor's specular representation, .a specular roughness
	float4 svgfLinZ    : SV_Target4;   // SVGF-specific buffer containing linear z, max z-derivs, last frame's z, obj-space normal
	float4 svgfMoVec   : SV_Target5;   // SVGF-specific buffer containing motion vector and fwidth of pos & normal
	float4 svgfCompact : SV_Target6;   // SVGF-specific buffer containing duplicate data that allows reducing memory traffic in some passes
};

// Define pi
#define M_1_PI  0.318309886183790671538

// Convert our world space direction to a (u,v) coord in a latitude-longitude spherical map
float2 wsVectorToLatLong(float3 dir)
{
	float3 p = normalize(dir);
	float u = (1.f + atan2(p.x, -p.z) * M_1_PI) * 0.5f;
	float v = acos(p.y) * M_1_PI;
	return float2(u, v);
}

GBuffer main(float2 texC : TEXCOORD, float4 pos : SV_Position) 
{
	// Compute our ray direction from the camera through the center of the pixel
	float2 ndc = float2(2, -2) * texC + float2(-1, 1);
	float3 rayDir = ndc.x * gCamera.cameraU + ndc.y * gCamera.cameraV + gCamera.cameraW;

	// Load a color from our background environment map
	float2 dims;
	gEnvMap.GetDimensions(dims.x, dims.y);
	float2 uv = wsVectorToLatLong(rayDir);
	float3 bgColor = gEnvMap[uint2(uv * dims)].rgb;

	// Clear our G-buffer channels
	GBuffer gBufOut;
	gBufOut.wsPos = float4(0.0f, 0.0f, 0.0f, 0.0f);
	gBufOut.wsNorm = float4(0.0f, 0.0f, 0.0f, 0.0f);
	gBufOut.matDif = float4(bgColor, 0.0f);
	gBufOut.matSpec = float4(0.0f, 0.0f, 0.0f, 0.0f);
	gBufOut.svgfLinZ = float4(0.0f, 0.0f, 0.0f, 0.0f);
	gBufOut.svgfMoVec = float4(0.0f, 0.0f, 0.0f, 0.0f);
    return gBufOut;
}
