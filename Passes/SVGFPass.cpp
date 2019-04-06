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

// Implementation of the SVGF paper.  For details, please see this paper:
//       http://research.nvidia.com/publication/2017-07_Spatiotemporal-Variance-Guided-Filtering%3A

#include "SVGFPass.h"

namespace {
	// Where is our shaders located?
	const char *kReprojectShader         = "SVGF\\SVGFReproject.ps.hlsl";
	const char *kAtrousShader            = "SVGF\\SVGFAtrous.ps.hlsl";
	const char *kModulateShader          = "SVGF\\SVGFModulate.ps.hlsl";
	const char *kFilterMomentShader      = "SVGF\\SVGFFilterMoments.ps.hlsl";
	const char *kCombineUnfilteredShader = "SVGF\\SVGFCombineUnfiltered.ps.hlsl";
};

SVGFPass::SharedPtr SVGFPass::create(const std::string &directIn, const std::string &indirectIn, const std::string &outChannel)
{
	return SharedPtr(new SVGFPass(directIn, indirectIn, outChannel));
}

SVGFPass::SVGFPass(const std::string &directIn, const std::string &indirectIn, const std::string &outChannel)
	: RenderPass( "Spatiotemporal Filter (SVGF)", "SVGF Options" )
{
	mDirectInTexName   = directIn;
	mIndirectInTexName = indirectIn;
	mOutTexName        = outChannel;
}

bool SVGFPass::initialize(RenderContext* pRenderContext, ResourceManager::SharedPtr pResManager)
{
	// Stash a copy of our resource manager so we can get rendering resources
	mpResManager = pResManager;

	// Set our input textures / resources.  These are managed by our resource manager, and are
	//    created each frame by earlier render passes.
	mpResManager->requestTextureResource("WorldPosition");
	mpResManager->requestTextureResource(mDirectInTexName);
	mpResManager->requestTextureResource(mIndirectInTexName);
	mpResManager->requestTextureResource("SVGF_LinearZ");
	mpResManager->requestTextureResource("SVGF_MotionVecs");
	mpResManager->requestTextureResource("SVGF_CompactNormDepth");
	mpResManager->requestTextureResource("OutDirectAlbedo");
	mpResManager->requestTextureResource("OutIndirectAlbedo");

	// Set the output channel
	mpResManager->requestTextureResource(mOutTexName);

	// Create our graphics state
	mpSvgfState = GraphicsState::create();

	// Setup our filter shaders
	mpReprojection      = FullscreenLaunch::create(kReprojectShader);
	mpAtrous            = FullscreenLaunch::create(kAtrousShader);
	mpModulate          = FullscreenLaunch::create(kModulateShader);
	mpFilterMoments     = FullscreenLaunch::create(kFilterMomentShader);
	mpCombineUnfiltered = FullscreenLaunch::create(kCombineUnfilteredShader);

	// Our GUI needs more space than other passes, so enlarge the GUI window.
	setGuiSize(ivec2(250, 350));

    return true;
}

void SVGFPass::resize(uint32_t width, uint32_t height)
{
	// Skip if we're resizing to 0 width or height.
	if (width <= 0 || height <= 0) return;

	// Have 3 different types of framebuffers and resources.  Reallocate them whenever screen resolution changes.

	{   // Type 1, Screen-size FBOs with 2 RGBA32F MRTs
		Fbo::Desc desc;
		desc.setSampleCount(0);
		desc.setColorTarget(0, ResourceFormat::RGBA32Float);
		desc.setColorTarget(1, ResourceFormat::RGBA32Float);
		mpPingPongFbo[0]  = FboHelper::create2D(width, height, desc);
		mpPingPongFbo[1]  = FboHelper::create2D(width, height, desc);
		mpFilteredPastFbo = FboHelper::create2D(width, height, desc);
	}

	{   // Type 2, Screen-size FBOs with 4 MRTs, 3 that are RGBA32F, one that is R16F
		Fbo::Desc desc;
		desc.setSampleCount(0);
		desc.setColorTarget(0, Falcor::ResourceFormat::RGBA32Float); // direct
		desc.setColorTarget(1, Falcor::ResourceFormat::RGBA32Float); // indirect
		desc.setColorTarget(2, Falcor::ResourceFormat::RGBA32Float); // moments
		desc.setColorTarget(3, Falcor::ResourceFormat::R16Float);    // history length
		mpCurReprojFbo  = FboHelper::create2D(width, height, desc);
		mpPrevReprojFbo = FboHelper::create2D(width, height, desc);
	}

	{   // Type 3, Screen-size FBOs with 1 RGBA32F buffer
		Fbo::Desc desc;
		desc.setColorTarget(0, Falcor::ResourceFormat::RGBA32Float);
		mpOutputFbo = FboHelper::create2D(width, height, desc);
	}

	// We're manually keeping a copy of our linear Z G-buffers from frame N for use in rendering frame N+1
	mInputTex.prevLinearZ = Texture::create2D(width, height, ResourceFormat::RGBA32Float, 1, 1, nullptr, Resource::BindFlags::ShaderResource | Resource::BindFlags::UnorderedAccess | Resource::BindFlags::RenderTarget);

	mNeedFboClear = true;
}

void SVGFPass::clearFbos(RenderContext* pCtx)
{
	// Clear our FBOs
	pCtx->clearFbo(mpPrevReprojFbo.get(), glm::vec4(0), 1.0f, 0, FboAttachmentType::All);
	pCtx->clearFbo(mpCurReprojFbo.get(), glm::vec4(0), 1.0f, 0, FboAttachmentType::All);
	pCtx->clearFbo(mpFilteredPastFbo.get(), glm::vec4(0), 1.0f, 0, FboAttachmentType::All);
	pCtx->clearFbo(mpPingPongFbo[0].get(), glm::vec4(0), 1.0f, 0, FboAttachmentType::All);
	pCtx->clearFbo(mpPingPongFbo[1].get(), glm::vec4(0), 1.0f, 0, FboAttachmentType::All);

	// Clear our history textures
	pCtx->clearUAV(mInputTex.prevLinearZ->getUAV().get(), vec4(0.f, 0.f, 0.f, 1.f));

	mNeedFboClear = false;
}

void SVGFPass::renderGui(Gui* pGui)
{
	// Commented out GUI fields don't currently work with the current SVGF implementation
	int dirty = 0;
	dirty |= (int)pGui->addCheckBox(mFilterEnabled ? "SVGF enabled" : "SVGF disabled", mFilterEnabled);

	pGui->addText("");
	pGui->addText("Number of filter iterations.  Which");
	pGui->addText("    iteration feeds into future frames?");
	dirty |= (int)pGui->addIntVar("Iterations", mFilterIterations, 2, 10, 1);
	dirty |= (int)pGui->addIntVar("Feedback", mFeedbackTap, -1, mFilterIterations-2, 1);

	pGui->addText("");
	pGui->addText("Contol edge stopping on bilateral fitler");
	dirty |= (int)pGui->addFloatVar("For Color", mPhiColor, 0.0f, 10000.0f, 0.01f);
	//dirty |= (int)pGui->addFloatVar("For Normal", mPhiNormal, 0.001f, 10000.0f, 0.001f);

	pGui->addText("");
	pGui->addText("How much history should be used?");
	pGui->addText("    (alpha; 0 = full reuse; 1 = no reuse)");
	dirty |= (int)pGui->addFloatVar("Alpha", mAlpha, 0.0f, 1.0f, 0.001f);
	dirty |= (int)pGui->addFloatVar("Moments Alpha", mMomentsAlpha, 0.0f, 1.0f, 0.001f);

	if (dirty)
	{
        // Flag to the renderer that options that affect the rendering have changed.
        setRefreshFlag();
	}
}

void SVGFPass::execute(RenderContext* pRenderContext)
{
	// Ensure we have received information about our rendering state, or we can't render.
	if (!mpResManager) return;

	// Grab our output texture  Make sure it exists
	Texture::SharedPtr pDst = mpResManager->getTexture(mOutTexName);
	if (!pDst) return;

	// Do we need to clear our internal framebuffers?  If so, do it.
	if (mNeedFboClear) clearFbos(pRenderContext);

	// Set up our textures to point appropriately
	mInputTex.directIllum   = mpResManager->getTexture(mDirectInTexName);
	mInputTex.indirectIllum = mpResManager->getTexture(mIndirectInTexName);
	mInputTex.linearZ       = mpResManager->getTexture("SVGF_LinearZ");
	mInputTex.motionVecs    = mpResManager->getTexture("SVGF_MotionVecs");
	mInputTex.miscBuf       = mpResManager->getTexture("SVGF_CompactNormDepth");
	mInputTex.dirAlbedo     = mpResManager->getTexture("OutDirectAlbedo");
	mInputTex.indirAlbedo   = mpResManager->getTexture("OutIndirectAlbedo");


	if (mFilterEnabled)
	{
		// Perform the major passes in SVGF filtering
		computeReprojection(pRenderContext);
		computeVarianceEstimate(pRenderContext);
		computeAtrousDecomposition(pRenderContext);

		// This performs the modulation in case there are no wavelet iterations performed
		if (mFilterIterations <= 0)
			computeModulation(pRenderContext);

		// Output the result of SVGF to the expected output buffer for subsequent passes.
		pRenderContext->blit(mpOutputFbo->getColorTexture(0)->getSRV(), pDst->getRTV());

		// Swap resources so we're ready for next frame.
		std::swap(mpCurReprojFbo, mpPrevReprojFbo);
		pRenderContext->blit(mInputTex.linearZ->getSRV(), mInputTex.prevLinearZ->getRTV());
	}
	else
	{
		// No SVGF.  Copy our input to our output
		//pRenderContext->blit(mpResManager->getTexture(mDirectInTexName)->getSRV(), pDst->getRTV());

		auto vars = mpCombineUnfiltered->getVars();
		vars["gDirect"]      = mInputTex.directIllum;
		vars["gIndirect"]    = mInputTex.indirectIllum;
		vars["gDirAlbedo"]   = mInputTex.dirAlbedo;
		vars["gIndirAlbedo"] = mInputTex.indirAlbedo;
		mpSvgfState->setFbo(mpResManager->createManagedFbo({ mOutTexName }));
		mpCombineUnfiltered->execute(pRenderContext, mpSvgfState);
	}
}



void SVGFPass::computeReprojection(RenderContext* pRenderContext)
{
	// Setup textures for our reprojection shader pass
	auto reproVars = mpReprojection->getVars();
	reproVars["gLinearZ"]       = mInputTex.linearZ;
	reproVars["gPrevLinearZ"]   = mInputTex.prevLinearZ;
	reproVars["gMotion"]        = mInputTex.motionVecs;
	reproVars["gPrevMoments"]   = mpPrevReprojFbo->getColorTexture(2);
	reproVars["gHistoryLength"] = mpPrevReprojFbo->getColorTexture(3);
	reproVars["gPrevDirect"]    = mpFilteredPastFbo->getColorTexture(0);
	reproVars["gPrevIndirect"]  = mpFilteredPastFbo->getColorTexture(1);
	reproVars["gDirect"]        = mInputTex.directIllum;
	reproVars["gIndirect"]      = mInputTex.indirectIllum;

	// Setup variables for our reprojection pass
	reproVars["PerImageCB"]["gAlpha"] = mAlpha;
	reproVars["PerImageCB"]["gMomentsAlpha"] = mMomentsAlpha;

	// Execute the reprojection pass
	mpSvgfState->setFbo(mpCurReprojFbo);
	mpReprojection->execute(pRenderContext, mpSvgfState);
}

void SVGFPass::computeVarianceEstimate(RenderContext* pRenderContext)
{
	auto filterVars = mpFilterMoments->getVars();
	filterVars["gDirect"]           = mpCurReprojFbo->getColorTexture(0);
	filterVars["gIndirect"]         = mpCurReprojFbo->getColorTexture(1);
	filterVars["gMoments"]          = mpCurReprojFbo->getColorTexture(2);
	filterVars["gHistoryLength"]    = mpCurReprojFbo->getColorTexture(3);
	filterVars["gCompactNormDepth"] = mInputTex.miscBuf;

	filterVars["PerImageCB"]["gPhiColor"]  = mPhiColor;
	filterVars["PerImageCB"]["gPhiNormal"] = mPhiNormal;

	mpSvgfState->setFbo(mpPingPongFbo[0]);
	mpFilterMoments->execute(pRenderContext, mpSvgfState);
}

void SVGFPass::computeAtrousDecomposition(RenderContext* pRenderContext)
{
	auto aTrousVars = mpAtrous->getVars();
	aTrousVars["PerImageCB"]["gPhiColor"]  = mPhiColor;
	aTrousVars["PerImageCB"]["gPhiNormal"] = mPhiNormal;
	aTrousVars["gHistoryLength"]           = mpCurReprojFbo->getColorTexture(3);
	aTrousVars["gCompactNormDepth"]        = mInputTex.miscBuf;


	for (int i = 0; i < mFilterIterations; i++) {
		bool performModulation = (i == mFilterIterations - 1);
		Fbo::SharedPtr curTargetFbo = performModulation ? mpOutputFbo : mpPingPongFbo[1];

		// Send down our input images
		aTrousVars["gDirect"] = mpPingPongFbo[0]->getColorTexture(0);
		aTrousVars["gIndirect"] = mpPingPongFbo[0]->getColorTexture(1);
		aTrousVars["PerImageCB"]["gStepSize"] = 1 << i;

		// perform modulation in-shader if needed
		aTrousVars["PerImageCB"]["gPerformModulation"] = performModulation;
		aTrousVars["gAlbedo"]      = mInputTex.dirAlbedo;
		aTrousVars["gIndirAlbedo"] = mInputTex.indirAlbedo;

		mpSvgfState->setFbo(curTargetFbo);
		mpAtrous->execute(pRenderContext, mpSvgfState);

		// store the filtered color for the feedback path
		if (i == std::min(mFeedbackTap, mFilterIterations - 1))
		{
			pRenderContext->blit(curTargetFbo->getColorTexture(0)->getSRV(), mpFilteredPastFbo->getRenderTargetView(0));
			pRenderContext->blit(curTargetFbo->getColorTexture(1)->getSRV(), mpFilteredPastFbo->getRenderTargetView(1));
		}

		std::swap(mpPingPongFbo[0], mpPingPongFbo[1]);
	}

	if (mFeedbackTap < 0 || mFilterIterations <= 0)
	{
		pRenderContext->blit(mpCurReprojFbo->getColorTexture(0)->getSRV(), mpFilteredPastFbo->getRenderTargetView(0));
		pRenderContext->blit(mpCurReprojFbo->getColorTexture(1)->getSRV(), mpFilteredPastFbo->getRenderTargetView(1));
	}

}

void SVGFPass::computeModulation(RenderContext* pRenderContext)
{
	auto modulateVars = mpModulate->getVars();
	modulateVars["gDirect"]      = mpCurReprojFbo->getColorTexture(0);
	modulateVars["gIndirect"]    = mpCurReprojFbo->getColorTexture(1);
	modulateVars["gDirAlbedo"]   = mInputTex.dirAlbedo;
	modulateVars["gIndirAlbedo"] = mInputTex.indirAlbedo;

	// Run the modulation pass
	mpSvgfState->setFbo(mpOutputFbo);
	mpModulate->execute(pRenderContext, mpSvgfState);
}

