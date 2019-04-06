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

#include "GBufferForSVGF.h"

namespace {
	// Where are our shaders located?
	const char *kGbufVertShader = "SVGFSampleOtherPasses\\gBufferSVGF.vs.hlsl";
    const char *kGbufFragShader = "SVGFSampleOtherPasses\\gBufferSVGF.ps.hlsl";
	const char *kClearToEnvMap  = "SVGFSampleOtherPasses\\clearGBuffer.ps.hlsl";
};

bool GBufferForSVGF::initialize(RenderContext* pRenderContext, ResourceManager::SharedPtr pResManager)
{
	// Stash a copy of our resource manager so we can get rendering resources
	mpResManager = pResManager;

	// We write these texture; tell our resource manager that we expect these channels to exist
	mpResManager->requestTextureResource("WorldPosition", ResourceFormat::RGBA32Float);
	mpResManager->requestTextureResource("WorldNormal", ResourceFormat::RGBA16Float);
	mpResManager->requestTextureResource("MaterialDiffuse", ResourceFormat::RGBA16Float);
	mpResManager->requestTextureResource("MaterialSpecRough", ResourceFormat::RGBA16Float);
	mpResManager->requestTextureResource("SVGF_LinearZ");
	mpResManager->requestTextureResource("SVGF_MotionVecs", ResourceFormat::RGBA16Float);
	mpResManager->requestTextureResource("SVGF_CompactNormDepth");
	mpResManager->requestTextureResource("Z-Buffer", ResourceFormat::D24UnormS8, ResourceManager::kDepthBufferFlags);

	// jfgagnon: force load some scene
	mpResManager->setDefaultSceneName("Data/pink_room/pink_room.fscene");

	// If the user loads an environment map, grab it here (to display in g-buffer)
	mpResManager->requestTextureResource(ResourceManager::kEnvironmentMap);

    // Since we're rasterizing, we need to define our raster pipeline state (though we use the defaults)
    mpGfxState = GraphicsState::create();

	// Create a graphics state (for our clear pass) with no depth writes
	mpStateNoDepthWrites = GraphicsState::create();
	DepthStencilState::Desc dsDesc; dsDesc.setDepthWriteMask(false).setDepthTest(false);
	mpStateNoDepthWrites->setDepthStencilState(DepthStencilState::create(dsDesc));

	// Create our wrapper for a scene-rasterization pass.
	mpRaster = RasterLaunch::createFromFiles(kGbufVertShader, kGbufFragShader);
	mpRaster->setScene(mpScene);

	// Create our wrapper for a full-screen raster pass to clear the g-buffer
	mpClearGBuf = FullscreenLaunch::create(kClearToEnvMap);

    return true;
}

void GBufferForSVGF::initScene(RenderContext* pRenderContext, Scene::SharedPtr pScene)
{
	// Stash a copy of the scene
	if (pScene)
		mpScene = pScene;

	// Update our raster pass wrapper with this scene
	if (mpRaster)
		mpRaster->setScene(mpScene);
}

void GBufferForSVGF::execute(RenderContext* pRenderContext)
{
	// Create a framebuffer for rendering.  (Creating once per frame is for simplicity, not performance).
	Fbo::SharedPtr outputFbo = mpResManager->createManagedFbo(
		{"WorldPosition","WorldNormal","MaterialDiffuse","MaterialSpecRough","SVGF_LinearZ","SVGF_MotionVecs","SVGF_CompactNormDepth"},
		"Z-Buffer" );

    // Failed to create a valid FBO?  We're done.
    if (!outputFbo) return;

	// Clear our g-buffer's depth buffer (clear depth to 1, stencil to 0)
	pRenderContext->clearDsv( outputFbo->getDepthStencilView().get(), 1.0f, 0 );

	// Clear our framebuffer to the background environment map (and zeros elsewhere in the buffer)
	mpClearGBuf->getVars()["gEnvMap"] = mpResManager->getTexture(ResourceManager::kEnvironmentMap);   // Get our env. map (default one is filled with blue)
	mpClearGBuf->setCamera(mpScene->getActiveCamera());                                    // Pass camera data to shader (Falcor doesn't do this automatically for FSPases)
	mpStateNoDepthWrites->setFbo(outputFbo);                                               // Don't want this "clear" pass to change z-value
	mpClearGBuf->execute(pRenderContext, mpStateNoDepthWrites);                            // Do our clear.

	// Pass down our output size to the G-buffer shader
	auto shaderVars = mpRaster->getVars();
	vec2 fboSize = vec2(outputFbo->getWidth(), outputFbo->getHeight());
	shaderVars["GBufCB"]["gBufSize"] = vec4(fboSize.x, fboSize.y, 1.0f / fboSize.x, 1.0f / fboSize.y);

	// Execute our rasterization pass.  Note: Falcor will populate many built-in shader variables
	mpRaster->execute(pRenderContext, mpGfxState, outputFbo);
}
