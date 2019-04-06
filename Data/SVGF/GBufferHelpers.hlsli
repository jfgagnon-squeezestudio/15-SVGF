// Helper functions for generating the G-buffer

#include "Graphics/RenderData/RenderData.hlsli"
#include "Renderer/MultiPassRenderer/RenderParams.h"
#include "GBufferParams.hlsli"

cbuffer PerFrameCB
{
    RenderParams    gRenderParams;
    GBufferParams   gParams;
};

// TODO: These clash with the functions in Utils/PackedFormatConversion.hlsli. Added TEMP_ prefix.
// The definition differs, as these do half conversion, the others snorm.

uint TEMP_packSnorm2x16(float2 val)
{
	uint l = asuint(f32tof16(val.x));
	uint h = asuint(f32tof16(val.y));

	return (h << 16) + l;
}

float2 TEMP_unpackSnorm2x16(uint val)
{
	uint l = (val) & 0xffff;
	uint h = (val >> 16) & 0xffff;

	return float2(f16tof32(l), f16tof32(h));
}

float2 sign_not_zero(float2 v) 
{ 
	return step(0.0, v) * 2.0 - (float2)(1.0); 
}

// TODO: We have octahedral mapping helpers in Utils/MathHelpers.slang. Remove these and update the code.

/** Encodes a float3 direction to an octahedral representation in a 32-bit uint
*/
uint dir_to_oct(float3 normal)
{
	float2 p = normal.xy * (1.0 / dot(abs(normal), 1.0.xxx));
	float2 e = normal.z > 0.0
		? p
		: (1.0 - abs(p.yx)) * sign_not_zero(p);
	return TEMP_packSnorm2x16(e);
}

/** Decodes a 32-bit uint octahedral encoding back to a float3 direction 
*/
float3 oct_to_dir(uint octo)
{
	float2 e = TEMP_unpackSnorm2x16(octo);
	float3 v = float3(e, 1.0 - abs(e.x) - abs(e.y));
	if (v.z < 0.0)
		v.xy = (1.0 - abs(v.yx)) * sign_not_zero(v.xy);
	return normalize(v);
}

/** Transforms homogeneous clip space position to normalized screen space coordinates.
*/
float2 clipPosToNormalizedScreenPos(float4 posH)
{
    return (posH.xy / posH.w) * float2(0.5, -0.5) + float2(0.5, 0.5);
}

/** Computes motion vector from current frame to previous frame.
    \return Motion vector in normalized screen space coordinates, where (0,0) is top-left corner and (1,1) is bottom-right.
*/
float2 calcMotionVector(float4 prevClipPos, float2 currentPixelPos)
{
    float2 motionVec = clipPosToNormalizedScreenPos(prevClipPos) - (currentPixelPos * gParams.invFrameSize);

    // Guard against inf/nan due to projection by w <= 0.
    const float epsilon = 1e-5f;
    if (prevClipPos.w < epsilon) motionVec = float2(0, 0);

    return motionVec;
}

/** Returns a float2 with the length(fwidth()) of both a position and normal
*/
float2 calcPosNormFWidth(float3 pos, float3 norm)
{
	return float2(length(fwidth(pos)), length(fwidth(norm)));
}

/** Helper function to store G-buffer channels derived from Falcor's HitPoint struct as UAV/RTV.
    The returned RenderDataOutput struct can be directly returned from a raster pass to be written to the render target(s).
*/
void storeGBufferOutput(HitPoint hitPt, uint2 pixelPos, inout RenderDataOutput psOut)
{
    // Note:
    // The code is a _bit_ ugly as we have to ensure already in the preprocessor that writes to the RenderDataOutput struct's SV_TargetN variables
    // are only generated if a) channel exists and b) is bound as RTV. Otherwise we get fxc compiler errors from the generated code, even if it can never be reached.
    // Second we must rely on preprocessor string concatenation to let a BufId_<name> be attached to a particular render target slot in the output struct.
    // Unfortunately, we cannot use macro expansion to hide this, as macros cannot contain nested #ifdef/#if etc.

    // Geometry channels.
    float4 _WorldPosition = float4(hitPt.posW, 1.f);
    float4 _WorldShadingNormal = float4(hitPt.N, 0.f);
    float4 _WorldShadingBitangent = float4(hitPt.B, 0.f);
    float4 _TexCoord = float4(hitPt.uv, 0.f, 0.f);

	// Stuff distance from camera to hitpoint in normal's w-component
    // TODO: Put this somewhere else.
	_WorldShadingNormal.w = length( hitPt.posW - gCam.posW );

    // Material channels. We use our helper functions to extract these.
    MaterialParams matParams = getHitPointMaterial(hitPt);
    float4 _MaterialDiffuseOpacity = matParams.diffuseOpacity;
    float4 _MaterialSpecularRoughness = matParams.specularRoughness;
    float4 _MaterialExtraParams = matParams.extraParams;

#ifdef BufId_WorldPosition
#if IS_UAV(BufId_WorldPosition)
    storeUAV(BufId_WorldPosition, pixelPos, _WorldPosition);
#elif IS_RTV(BufId_WorldPosition)
    storeRawRTV(BufId_WorldPosition, psOut, pack(BufId_WorldPosition, _WorldPosition));
#endif
#endif

#ifdef BufId_WorldShadingNormal
#if IS_UAV(BufId_WorldShadingNormal)
    storeUAV(BufId_WorldShadingNormal, pixelPos, _WorldShadingNormal);
#elif IS_RTV(BufId_WorldShadingNormal)
    storeRawRTV(BufId_WorldShadingNormal, psOut, pack(BufId_WorldShadingNormal, _WorldShadingNormal));
#endif
#endif

#ifdef BufId_WorldShadingBitangent
#if IS_UAV(BufId_WorldShadingBitangent)
    storeUAV(BufId_WorldShadingBitangent, pixelPos, _WorldShadingBitangent);
#elif IS_RTV(BufId_WorldShadingBitangent)
    storeRawRTV(BufId_WorldShadingBitangent, psOut, pack(BufId_WorldShadingBitangent, _WorldShadingBitangent));
#endif
#endif

#ifdef BufId_TexCoord
#if IS_UAV(BufId_TexCoord)
    storeUAV(BufId_TexCoord, pixelPos, _TexCoord);
#elif IS_RTV(BufId_TexCoord)
    storeRawRTV(BufId_TexCoord, psOut, pack(BufId_TexCoord, _TexCoord));
#endif
#endif

#ifdef BufId_MaterialDiffuseOpacity
#if IS_UAV(BufId_MaterialDiffuseOpacity)
    storeUAV(BufId_MaterialDiffuseOpacity, pixelPos, _MaterialDiffuseOpacity);
#elif IS_RTV(BufId_MaterialDiffuseOpacity)
    storeRawRTV(BufId_MaterialDiffuseOpacity, psOut, pack(BufId_MaterialDiffuseOpacity, _MaterialDiffuseOpacity));
#endif
#endif

#ifdef BufId_MaterialSpecularRoughness
#if IS_UAV(BufId_MaterialSpecularRoughness)
    storeUAV(BufId_MaterialSpecularRoughness, pixelPos, _MaterialSpecularRoughness);
#elif IS_RTV(BufId_MaterialSpecularRoughness)
    storeRawRTV(BufId_MaterialSpecularRoughness, psOut, pack(BufId_MaterialSpecularRoughness, _MaterialSpecularRoughness));
#endif
#endif

#ifdef BufId_MaterialExtraParams
#if IS_UAV(BufId_MaterialExtraParams)
    storeUAV(BufId_MaterialExtraParams, pixelPos, _MaterialExtraParams);
#elif IS_RTV(BufId_MaterialExtraParams)
    storeRawRTV(BufId_MaterialExtraParams, psOut, pack(BufId_MaterialExtraParams, _MaterialExtraParams));
#endif
#endif
}
