__import Shading;           // Imports ShaderCommon and DefaultVS, plus material evaluation
__import DefaultVS;         // VertexOut declaration

#include "GBufferHelpers.hlsli"
#include "GBufferVertexOut.hlsli"

/** Entry point for G-buffer rasterization pixel shader.
*/
RenderDataOutput main(GBufVertexOut vsOut, uint primID : SV_PrimitiveID, float4 pos : SV_Position)
{
    if (applyAlphaTest(vsOut.base, gMaterial)) discard;
    HitPoint hitPt = prepareHitPoint(vsOut.base, gMaterial, gCam.posW);

    RenderDataOutput psOut;

#ifdef BufId_MotionVector
#if IS_RTV(BufId_MotionVector)
    float2 motionVec = calcMotionVector(vsOut.base.prevPosH, pos.xy) + float2(gCam.jitterX, -gCam.jitterY);     // Remove camera jitter from motion vector
    storeRawRTV(BufId_MotionVector, psOut, pack(BufId_MotionVector, float4(motionVec, 0.f, 0.f)));
#endif
#endif
    
#ifdef BufId_MeshPrimIDs
#if IS_RTV(BufId_MeshPrimIDs)
    storeRawRTV(BufId_MeshPrimIDs, psOut, pack(BufId_MeshPrimIDs, float4(asfloat(gMeshId), asfloat(primID), 1.0f, 0.0f)));
#endif
#endif

#ifdef BufId_SVGFPackedLinearZ
#if IS_RTV(BufId_SVGFPackedLinearZ)
	float linearZ = vsOut.base.posH.z * vsOut.base.posH.w;
	float4 packedLinZ = float4(linearZ,                                           // Linear Z
		                       max(abs(ddx(linearZ)), abs(ddy(linearZ))),         // Max absolute change in z
		                       vsOut.base.prevPosH.z,                             // Last frame z
		                       asfloat(dir_to_oct(normalize(vsOut.normalObj))));  // Object space normal, in packed oct16 format
	storeRawRTV(BufId_SVGFPackedLinearZ, psOut, pack(BufId_SVGFPackedLinearZ, float4(packedLinZ)));
#endif
#endif

#ifdef BufId_SVGFMotionVector
#if IS_RTV(BufId_SVGFMotionVector)
    // This channels packs the regular motion vector (same as BufId_MotionVector in xy) and custom SVGF parameters in zw, which are not supported in ray tracing mode.
    // TODO: Pack all SVGF specific things in one or more specialized channels, away from the general things like motion vectors which is useful to non-SVGF pipelines.
    float2 svgfMotionVec = calcMotionVector(vsOut.base.prevPosH, pos.xy) + float2(gCam.jitterX, -gCam.jitterY);     // Remove camera jitter from motion vector
    float2 posNormFWidth = calcPosNormFWidth(hitPt.posW, hitPt.N);
    storeRawRTV(BufId_SVGFMotionVector, psOut, pack(BufId_SVGFMotionVector, float4(svgfMotionVec, posNormFWidth)));
#endif
#endif

#ifdef BufId_BFFPackedGeom
#if IS_RTV(BufId_BFFPackedGeom)
    float3 shadingNormal = normalize(hitPt.N);
    uint shadingNormalZSign = uint(asint(shadingNormal.z) >> 31 & 1);
    float4 packedGeom = float4(shadingNormal.x, shadingNormal.y, ((gMeshId & 0xff) | (shadingNormalZSign << 8)), vsOut.base.posH.z / vsOut.base.posH.w);
    storeRawRTV(BufId_BFFPackedGeom, psOut, pack(BufId_BFFPackedGeom, float4(packedGeom)));
#endif
#endif

#ifdef BufId_BFFPackedMaterial
#if IS_RTV(BufId_BFFPackedMaterial)
    MaterialParams matParams = getHitPointMaterial(hitPt);
    float4 _MaterialDiffuseOpacity = matParams.diffuseOpacity;
    float4 _MaterialSpecularRoughness = matParams.specularRoughness;
    float4 packedMaterial = float4(_MaterialDiffuseOpacity.rgb + _MaterialSpecularRoughness.rgb, _MaterialSpecularRoughness.a);
    storeRawRTV(BufId_BFFPackedMaterial, psOut, pack(BufId_BFFPackedMaterial, float4(packedMaterial)));
#endif
#endif

#ifdef BufId_BFFPackedHitPos
#if IS_RTV(BufId_BFFPackedHitPos)
    float4 packedHitPos = float4(hitPt.posW.xyz, vsOut.base.prevPosH.z / vsOut.base.prevPosH.w);
    storeRawRTV(BufId_BFFPackedHitPos, psOut, pack(BufId_BFFPackedHitPos, float4(packedHitPos)));
#endif
#endif

#ifdef BufId_WorldGeomNormal
	float3 dPosX = ddx(hitPt.posW.xyz);
	float3 dPosY = ddy(hitPt.posW.xyz);
	float4 appoxGeomNorm = float4( normalize(cross(dPosX, -dPosY)), 0.0f );
#if IS_UAV(BufId_WorldGeomNormal)
	storeUAV(BufId_WorldGeomNormal, pixelPos, appoxGeomNorm);
#elif IS_RTV(BufId_WorldGeomNormal)
	storeRawRTV(BufId_WorldGeomNormal, psOut, pack(BufId_WorldGeomNormal, appoxGeomNorm));
#endif
#endif

	storeGBufferOutput(hitPt, pos.xy, psOut);

    return psOut;
}
