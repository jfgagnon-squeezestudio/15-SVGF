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

// Some shared Falcor stuff for talking between CPU and GPU code
#include "HostDeviceSharedMacros.h"
#include "HostDeviceData.h"

// Include and import common Falcor utilities and data structures
import Raytracing;                   // Shared ray tracing specific functions & data
import ShaderCommon;                 // Shared shading data structures
import Shading;                      // Shading functions, etc
import Lights;                       // Light structures for our current scene

// A separate file with some simple utility functions: getPerpendicularVector(), initRand(), nextRand()
#include "ggxGlobalIlluminationUtils.hlsli"

// Include shader entries, data structures, and utility functions to spawn rays
#include "standardShadowRay.hlsli"
#include "indirectRay.hlsli"

// A constant buffer we'll populate from our C++ code  (used for our ray generation shader)
cbuffer RayGenCB
{
	float gMinT;           // Min distance to start a ray to avoid self-occlusion
	uint  gFrameCount;     // An integer changing every frame to update the random number
	bool  gDoIndirectGI;   // A boolean determining if we should shoot indirect GI rays
	bool  gDoDirectGI;     // A boolean determining if we should compute direct lighting
}

// Input textures that need to be set by the C++ code (for the ray gen shader)
Texture2D<float4> gPos;
Texture2D<float4> gNorm;
Texture2D<float4> gDiffuseMatl;
Texture2D<float4> gSpecMatl;

// Output textures that need to be set by the C++ code (for the ray gen shader)
RWTexture2D<float4> gDirectOut;
RWTexture2D<float4> gIndirectOut;
RWTexture2D<float4> gOutAlbedo;
RWTexture2D<float4> gIndirAlbedo;

// Input and out textures that need to be set by the C++ code (for the miss shader)
Texture2D<float4> gEnvMap;

[shader("raygeneration")]
void SimpleDiffuseGIRayGen()
{
	// Where is this ray on screen?
	uint2 launchIndex    = DispatchRaysIndex().xy;
	uint2 launchDim      = DispatchRaysDimensions().xy;

	// Load g-buffer data
	float4 worldPos      = gPos[launchIndex];
	float4 worldNorm     = gNorm[launchIndex];
	float4 difMatlColor  = gDiffuseMatl[launchIndex];
	float4 specMatlColor = gSpecMatl[launchIndex];

	// Does this g-buffer pixel contain a valid piece of geometry?  (0 in pos.w for invalid)
	bool isGeometryValid = (worldPos.w != 0.0f);

	// Extract some material parameters
	float roughness      = specMatlColor.a * specMatlColor.a;
	float3 toCamera      = normalize(gCamera.posW - worldPos.xyz);

	// Check if we're looking at the back of a double-sided material (and if so, flip normal)
	float NdotV = dot(worldNorm.xyz, toCamera);

	// Initialize our random number generator
	uint randSeed = initRand(launchIndex.x + launchIndex.y * launchDim.x, gFrameCount, 16);

	// Do shading, if we have geoemtry here (otherwise, output the background color)
	if (isGeometryValid)
	{
		// (Optionally) do explicit direct lighting to a random light in the scene
		if (gDoDirectGI)
		{
			// Pick a random light from our scene to sample for direct lighting
			int lightToSample = min(int(nextRand(randSeed) * gLightsCount), gLightsCount - 1);

			// We need to query our scene to find info about the current light
			float distToLight;
			float3 lightIntensity;
			float3 toLight;
			getLightData(lightToSample, worldPos.xyz, toLight, lightIntensity, distToLight);

			// Compute our cosine / NdotL term
			float NdotL = saturate(dot(worldNorm.xyz, toLight));

			// Shoot our ray for our direct lighting
			float shadowMult = float(gLightsCount) * shadowRayVisibility(worldPos.xyz, toLight, gMinT, distToLight);

			// Compute our GGX color
			float3 ggxTerm = getGGXColor(toCamera, toLight, worldNorm.xyz, NdotV, specMatlColor.rgb, roughness, true);

			// Compute direct color.  Split into light and albedo terms for our SVGF filter
			float3 directColor = shadowMult * lightIntensity * NdotL;
			float3 directAlbedo = ggxTerm + difMatlColor.rgb / M_PI;
			bool colorsNan = any(isnan(directColor)) || any(isnan(directAlbedo));
			gDirectOut[launchIndex] = float4(colorsNan ? float3(0, 0, 0) : directColor, 1.0f);
			gOutAlbedo[launchIndex] = float4(colorsNan ? float3(0, 0, 0) : directAlbedo, 1.0f);
		}

		// (Optionally) do indirect lighting for global illumination
		if (gDoIndirectGI)
		{
			// We have to decide whether we sample our diffuse or specular lobe.
			float probDiffuse   = probabilityToSampleDiffuse(difMatlColor.rgb, specMatlColor.rgb);
			float chooseDiffuse = (nextRand(randSeed) < probDiffuse);

			float3 bounceDir;
			if (chooseDiffuse)
			{   // Randomly select to bounce in our diffuse lobe
				bounceDir = getCosHemisphereSample(randSeed, worldNorm.xyz);
			}
			else
			{   // Randomyl select to bounce in our GGX lobe
				bounceDir = getGGXSampleDir(randSeed, roughness, worldNorm.xyz, toCamera);
			}

			// Shoot our indirect color ray
			float3 bounceColor = shootIndirectRay(worldPos.xyz, bounceDir, gMinT, 0, randSeed);

			// Compute diffuse, ggx shading terms
			float  NdotL = saturate(dot(worldNorm.xyz, bounceDir));
			float3 difTerm = max( 5e-3f, difMatlColor.rgb / M_PI );
			float3 ggxTerm = NdotL * getGGXColor(toCamera, bounceDir, worldNorm.xyz, NdotV, specMatlColor.rgb, roughness, false);

			// Split into an incoming light and "indirect albedo" term to help filter illumination despite sampling 2 different lobes
			float3 difFinal = float3(1.0f) / probDiffuse;                    // Has been divided by difTerm.  Multiplied back post-SVGF
			float3 ggxFinal = ggxTerm / (difTerm * (1.0f - probDiffuse));    // Has been divided by difTerm.  Multiplied back post-SVGF
			float3 shadeColor = bounceColor * (chooseDiffuse ? difFinal : ggxFinal);

			bool colorsNan = any(isnan(shadeColor));
			gIndirectOut[launchIndex] = float4(colorsNan ? float3(0, 0, 0) : shadeColor, 1.0f);
			gIndirAlbedo[launchIndex] = float4(difTerm, 1.0f);
		}
	}
	else
	{
		// If we hit the background color, return reasonable values that won't mess up the SVGF filter
		gDirectOut[launchIndex] = float4(difMatlColor.rgb, 1.0f);    // DifMatlColor is the env. map color, in this case
		gIndirectOut[launchIndex] = float4(0.0f, 0.0f, 0.0f, 1.0f);
		gOutAlbedo[launchIndex] = float4(1.0f, 1.0f, 1.0f, 1.0f);
	}
}
