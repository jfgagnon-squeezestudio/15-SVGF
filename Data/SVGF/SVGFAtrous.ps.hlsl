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

__import Helpers;
__import ShaderCommon;
__import Shading;

#include "SVGFCommon.h"
#include "SVGFEdgeStoppingFunctions.h"
#include "SVGFPackNormal.h"

cbuffer PerImageCB : register(b0)
{
    Texture2D   gDirect;
    Texture2D   gIndirect;
    Texture2D   gCompactNormDepth;
    Texture2D   gHistoryLength;
    Texture2D   gAlbedo;
	Texture2D   gIndirAlbedo;
    int         gStepSize;
    float       gPhiColor;
    float       gPhiNormal;
    bool        gPerformModulation;
};

// computes a 3x3 gaussian blur of the variance, centered around
// the current pixel
float2 computeVarianceCenter(int2 ipos, Texture2D sDirect, Texture2D sIndirect)
{
    float2 sum = float2(0.0, 0.0);

    const float kernel[2][2] = {
        { 1.0 / 4.0, 1.0 / 8.0  },
        { 1.0 / 8.0, 1.0 / 16.0 }
    };

    const int radius = 1;
    for (int yy = -radius; yy <= radius; yy++)
    {
        for (int xx = -radius; xx <= radius; xx++)
        {
            int2 p = ipos + int2(xx, yy);

            float k = kernel[abs(xx)][abs(yy)];

            sum.r += sDirect.Load(int3(p, 0)).a * k;
            sum.g += sIndirect.Load(int3(p, 0)).a * k;
        }
    }

    return sum;
}

struct PS_OUT
{
    float4 OutDirect    : SV_TARGET0;
    float4 OutIndirect  : SV_TARGET1;
};

PS_OUT main(FullScreenPassVsOut vsOut)
{

    float4 fragCoord = vsOut.posH;
    const int2 ipos       = int2(fragCoord.xy);
    const int2 screenSize = getTextureDims(gDirect, 0);

    const float epsVariance      = 1e-10;
    const float kernelWeights[3] = { 1.0, 2.0 / 3.0, 1.0 / 6.0 };

    // constant samplers to prevent the compiler from generating code which
    // fetches the sampler descriptor from memory for each texture access
    const float4  directCenter    = gDirect.Load(int3(ipos, 0));
    const float4  indirectCenter  = gIndirect.Load(int3(ipos, 0));
    const float lDirectCenter   = luminance(directCenter.rgb);
    const float lIndirectCenter = luminance(indirectCenter.rgb);

    // variance for direct and indirect, filtered using 3x3 gaussin blur
    const float2 var = computeVarianceCenter(ipos, gDirect, gIndirect);

    // number of temporally integrated pixels
    const float historyLength = gHistoryLength.Load(int3(ipos, 0)).r;

    float3 normalCenter;
    float2 zCenter;
    fetchNormalAndLinearZ(gCompactNormDepth, ipos, normalCenter, zCenter);

    PS_OUT psOut;

    if (zCenter.x < 0)
    {
        // not a valid depth => must be envmap => do not filter
        psOut.OutDirect   = directCenter;
        psOut.OutIndirect = indirectCenter;
        return psOut;
    }

    const float phiLDirect   = gPhiColor * sqrt(max(0.0, epsVariance + var.r));
    const float phiLIndirect = gPhiColor * sqrt(max(0.0, epsVariance + var.g));
    const float phiDepth     = max(zCenter.y, 1e-8) * gStepSize;

    // explicitly store/accumulate center pixel with weight 1 to prevent issues
    // with the edge-stopping functions
    float sumWDirect   = 1.0;
    float sumWIndirect = 1.0;
    float4  sumDirect    = directCenter;
    float4  sumIndirect  = indirectCenter;

    for (int yy = -2; yy <= 2; yy++)
    {
        for (int xx = -2; xx <= 2; xx++)
        {
            const int2 p     = ipos + int2(xx, yy) * gStepSize;
            const bool inside = all(greaterThanEqual(p, int2(0,0))) && all(lessThan(p, screenSize));

            const float kernel = kernelWeights[abs(xx)] * kernelWeights[abs(yy)];

            if (inside && (xx != 0 || yy != 0)) // skip center pixel, it is already accumulated
            {
                const float4 directP     = gDirect.Load(int3(p, 0));
                const float4 indirectP   = gIndirect.Load(int3(p, 0));

                float3 normalP;
                float2 zP;
                fetchNormalAndLinearZ(gCompactNormDepth, p, normalP, zP);
                const float lDirectP   = luminance(directP.rgb);
                const float lIndirectP = luminance(indirectP.rgb);

                // compute the edge-stopping functions
                const float2 w = computeWeight(
                    zCenter.x, zP.x, phiDepth * length(float2(xx, yy)),
					normalCenter, normalP, gPhiNormal, 
                    lDirectCenter, lDirectP, phiLDirect,
                    lIndirectCenter, lIndirectP, phiLIndirect);

                const float wDirect = w.x * kernel;
                const float wIndirect = w.y * kernel;

                // alpha channel contains the variance, therefore the weights need to be squared, see paper for the formula
                sumWDirect  += wDirect;
                sumDirect   += float4(wDirect.xxx, wDirect * wDirect) * directP;

                sumWIndirect  += wIndirect;
                sumIndirect   += float4(wIndirect.xxx, wIndirect * wIndirect) * indirectP;
            }
        }
    }

    // renormalization is different for variance, check paper for the formula
    psOut.OutDirect   = float4(sumDirect   / float4(sumWDirect.xxx,   sumWDirect   * sumWDirect  ));
    psOut.OutIndirect = float4(sumIndirect / float4(sumWIndirect.xxx, sumWIndirect * sumWIndirect));

    // do the demodulation in the last iteration to save memory bandwidth
    if(gPerformModulation)
    {
        psOut.OutDirect = (psOut.OutDirect * gAlbedo[ipos] + psOut.OutIndirect * gIndirAlbedo[ipos]);
    }

    return psOut;
}