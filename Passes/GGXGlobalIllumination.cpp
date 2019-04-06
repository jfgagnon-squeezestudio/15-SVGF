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

#include "GGXGlobalIllumination.h"

namespace {
	// Where is our shaders located?
	const char* kFileRayTrace = "SVGFSampleOtherPasses\\ggxGlobalIllumination.rt.hlsl";
};


GGXGlobalIlluminationPass::SharedPtr GGXGlobalIlluminationPass::create(const std::string &directOut, const std::string &indirectOut)
{
	return SharedPtr(new GGXGlobalIlluminationPass(directOut, indirectOut));
}

GGXGlobalIlluminationPass::GGXGlobalIlluminationPass(const std::string &directOut, const std::string &indirectOut)
	: RenderPass("Shoot Global Illumination Rays", "Global Illumination Options")
{
	mDirectOutName = directOut;
	mIndirectOutName = indirectOut;
}

bool GGXGlobalIlluminationPass::initialize(RenderContext* pRenderContext, ResourceManager::SharedPtr pResManager)
{
	// Stash a copy of our resource manager so we can get rendering resources
	mpResManager = pResManager;

	// Let our resource manager know that we expect some input buffers
	mpResManager->requestTextureResource("WorldPosition");     // Our fragment position, from G-buffer pass
	mpResManager->requestTextureResource("WorldNormal");       // Our fragment normal, from G-buffer pass
	mpResManager->requestTextureResource("MaterialDiffuse");   // Our fragment diffuse color, from G-buffer pass
	mpResManager->requestTextureResource("MaterialSpecRough"); // Our fragment specular color, from G-buffer pass
	mpResManager->requestTextureResource(ResourceManager::kEnvironmentMap);  // Our environment map

	// We'll be creating some output buffers.  We store illumination and albedo separately, so we can just
	//     filter illumination without blurring the albdeo (which we know accurately from our G-buffer)
	mpResManager->requestTextureResource(mDirectOutName);      // A buffer to store the direct illumination of each pixel's sample
	mpResManager->requestTextureResource(mIndirectOutName);    // A buffer to store the indirect illumination of each pixel's sample
	mpResManager->requestTextureResource("OutDirectAlbedo");   // A buffer to store the direct albedo of each pixel
	mpResManager->requestTextureResource("OutIndirectAlbedo"); // A buffer to store the indirect albedo of each pixel

	// Create our wrapper around a ray tracing pass; specify the entry point for our ray generation shader
	mpRays = RayLaunch::create(kFileRayTrace, "SimpleDiffuseGIRayGen");

	// Add ray type 0 (in this case, our shadow ray)
	mpRays->addMissShader(kFileRayTrace, "ShadowMiss");
	mpRays->addHitShader(kFileRayTrace, "ShadowClosestHit", "ShadowAnyHit");

	// Add ray type 1 (in this case, our indirect ray)
	mpRays->addMissShader(kFileRayTrace, "IndirectMiss");
	mpRays->addHitShader(kFileRayTrace, "IndirectClosestHit", "IndirectAnyHit");

	// Now that we've passed all our shaders in, compile and (if available) setup the scene
	mpRays->compileRayProgram();
	if (mpScene) mpRays->setScene(mpScene);

    return true;
}

void GGXGlobalIlluminationPass::initScene(RenderContext* pRenderContext, Scene::SharedPtr pScene)
{
	// Stash a copy of the scene and pass it to our ray tracer (if initialized)
    mpScene = std::dynamic_pointer_cast<RtScene>(pScene);
	if (!mpScene) return;
	if (mpRays) mpRays->setScene(mpScene);
}

void GGXGlobalIlluminationPass::renderGui(Gui* pGui)
{
	// Add a GUI in our options window allowing selective enabling / disabling of direct or indirect lighting
	int dirty = 0;
	dirty |= (int)pGui->addCheckBox(mDoDirectGI ? "Compute direct light" : "Skipping direct light", mDoDirectGI);
	dirty |= (int)pGui->addCheckBox(mDoIndirectGI ? "Computing indirect light" : "Skipping indirect light", mDoIndirectGI);

	if (dirty) setRefreshFlag();
}

void GGXGlobalIlluminationPass::execute(RenderContext* pRenderContext)
{
	// Get explicit pointers to the output buffers we're writing into.   (And clear them before returning the pointers.)
	Texture::SharedPtr pDirectDstTex         = mpResManager->getClearedTexture(mDirectOutName, vec4(0.0f, 0.0f, 0.0f, 0.0f));
	Texture::SharedPtr pIndirectDstTex       = mpResManager->getClearedTexture(mIndirectOutName, vec4(0.0f, 0.0f, 0.0f, 0.0f));
	Texture::SharedPtr pOutAlbedoTex         = mpResManager->getClearedTexture("OutDirectAlbedo", vec4(0.0f, 0.0f, 0.0f, 0.0f));
	Texture::SharedPtr pOutIndirectAlbedoTex = mpResManager->getClearedTexture("OutIndirectAlbedo", vec4(1.0f, 1.0f, 1.0f, 1.0f));

	// Do we have all the resources we need to render?  If not, return
	if (!pDirectDstTex || !pIndirectDstTex || !mpRays || !mpRays->readyToRender()) return;

	// Set our ray tracing shader variables
	auto rayGenVars = mpRays->getRayGenVars();
	rayGenVars["RayGenCB"]["gMinT"]         = mpResManager->getMinTDist();
	rayGenVars["RayGenCB"]["gFrameCount"]   = mFrameCount++;
	rayGenVars["RayGenCB"]["gDoIndirectGI"] = mDoIndirectGI;
	rayGenVars["RayGenCB"]["gDoDirectGI"]   = mDoDirectGI;
	rayGenVars["gPos"]         = mpResManager->getTexture("WorldPosition");
	rayGenVars["gNorm"]        = mpResManager->getTexture("WorldNormal");
	rayGenVars["gDiffuseMatl"] = mpResManager->getTexture("MaterialDiffuse");
	rayGenVars["gSpecMatl"]    = mpResManager->getTexture("MaterialSpecRough");
	rayGenVars["gDirectOut"]   = pDirectDstTex;
	rayGenVars["gIndirectOut"] = pIndirectDstTex;
	rayGenVars["gOutAlbedo"]   = pOutAlbedoTex;
	rayGenVars["gIndirAlbedo"] = pOutIndirectAlbedoTex;

	// Set our shader variables for the indirect miss ray
	auto missVars = mpRays->getMissVars(1);
	missVars["gEnvMap"] = mpResManager->getTexture(ResourceManager::kEnvironmentMap);

	// Shoot our rays and shade our primary hit points
	mpRays->execute( pRenderContext, mpResManager->getScreenSize() );
}


