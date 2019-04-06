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

struct IndirectRayPayload
{
	float3 color;
	uint   rndSeed;
};

// Utility to shoot an indirect ray using the DXR ray shaders defined in this header
float3 shootIndirectRay(float3 rayOrigin, float3 rayDir, float minT, uint curPathLen, uint seed)
{
	// Setup our indirect ray
	RayDesc rayColor;
	rayColor.Origin = rayOrigin;  // Where does it start?
	rayColor.Direction = rayDir;  // What direction do we shoot it?
	rayColor.TMin = minT;         // The closest distance we'll count as a hit
	rayColor.TMax = 1.0e38f;      // The farthest distance we'll count as a hit

								  // Initialize the ray's payload data with black return color and the current rng seed
	IndirectRayPayload payload;
	payload.color = float3(0, 0, 0);
	payload.rndSeed = seed;

	// Trace our ray to get a color in the indirect direction.  Use hit group #1 and miss shader #1
	TraceRay(gRtScene, 0, 0xFF, 1, hitProgramCount, 1, rayColor, payload);

	// Return the color we got from our ray
	return payload.color;
}


[shader("miss")]
void IndirectMiss(inout IndirectRayPayload rayData)
{
	// Load some information about our lightprobe texture
	float2 dims;
	gEnvMap.GetDimensions(dims.x, dims.y);

	// Convert our ray direction to a (u,v) coordinate
	float2 uv = wsVectorToLatLong(WorldRayDirection());

	// Load our background color, then store it into our ray payload
	rayData.color = gEnvMap[uint2(uv * dims)].rgb;
}

[shader("anyhit")]
void IndirectAnyHit(inout IndirectRayPayload rayData, BuiltInTriangleIntersectionAttributes attribs)
{
	// Is this a transparent part of the surface?  If so, ignore this hit
	if (alphaTestFails(attribs))
		IgnoreHit();
}

[shader("closesthit")]
void IndirectClosestHit(inout IndirectRayPayload rayData, BuiltInTriangleIntersectionAttributes attribs)
{
	// Run a helper functions to extract Falcor scene data for shading
	ShadingData shadeData = getHitShadingData(attribs);

	////////// Which light are we randomly sampling?
	////////int lightToSample = min(int(nextRand(rayData.rndSeed) * gLightsCount), gLightsCount - 1);

	////////// Get our light information
	////////float distToLight;
	////////float3 lightIntensity;
	////////float3 toLight;
	////////getLightData(lightToSample, shadeData.posW, toLight, lightIntensity, distToLight);

	////////// Compute our lambertion term (L dot N)
	////////float LdotN = saturate(dot(shadeData.N, toLight));

	////////// Shoot our shadow ray.
	////////float shadowMult = float(gLightsCount) * shadowRayVisibility(shadeData.posW, toLight, gMinT, distToLight);

	////////// Return the color illuminated by this randomly selected light
	////////rayData.color = shadowMult * LdotN * lightIntensity * shadeData.diffuse / M_PI;
	rayData.color = shadeData.diffuse;
}
