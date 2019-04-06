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

#pragma once
#include "../SharedUtils/RenderPass.h"
#include "../SharedUtils/SimpleVars.h"
#include "../SharedUtils/FullscreenLaunch.h"

/** This pass implements Spatiotemporal Variance-Guided Filtering from HPG 2017
*/
class SVGFPass : public ::RenderPass, inherit_shared_from_this<::RenderPass, SVGFPass>
{
public:
    using SharedPtr = std::shared_ptr<SVGFPass>;
    using SharedConstPtr = std::shared_ptr<const SVGFPass>;

	static SharedPtr create(const std::string &directIn, const std::string &indirectIn, const std::string &outChannel);
    virtual ~SVGFPass() = default;

protected:
	SVGFPass(const std::string &directIn, const std::string &indirectIn, const std::string &outChannel);

    // Implementation of RenderPass interface
	bool initialize(RenderContext* pRenderContext, ResourceManager::SharedPtr pResManager) override;
	void execute(RenderContext* pRenderContext) override;
	void renderGui(Gui* pGui) override;
	void resize(uint32_t width, uint32_t height) override;

	// Which texture inputs are we reading and writing to?
	std::string mDirectInTexName;
	std::string mIndirectInTexName;
	std::string mOutTexName;

	// The DX graphics state used internally in this pass
	GraphicsState::SharedPtr  mpSvgfState;

	// SVGF parameters
	int32_t mFilterIterations    = 4;
	int32_t mFeedbackTap         = 1;
	float   mVarainceEpsilon     = 1e-4f;
	float   mPhiColor            = 10.0f;
	float   mPhiNormal           = 128.0f;
	float   mAlpha               = 0.05f;
	float   mMomentsAlpha        = 0.2f;

	// jfgagnon
	int32_t mShowIntermediateBuffer = -1;

	// SVGF passes
	FullscreenLaunch::SharedPtr         mpReprojection;
	FullscreenLaunch::SharedPtr         mpAtrous;
	FullscreenLaunch::SharedPtr         mpModulate;
	FullscreenLaunch::SharedPtr         mpFilterMoments;
	FullscreenLaunch::SharedPtr         mpCombineUnfiltered;

	// Intermediate framebuffers
	Fbo::SharedPtr            mpPingPongFbo[2];
	Fbo::SharedPtr            mpFilteredPastFbo;
	Fbo::SharedPtr            mpCurReprojFbo;
	Fbo::SharedPtr            mpPrevReprojFbo;
	Fbo::SharedPtr            mpOutputFbo;

	// Textures expected by SVGF code
	struct {
		Texture::SharedPtr    miscBuf;
		Texture::SharedPtr    linearZ;
		Texture::SharedPtr    prevLinearZ;
		Texture::SharedPtr    dirAlbedo;
		Texture::SharedPtr    indirAlbedo;
		Texture::SharedPtr    motionVecs;
		Texture::SharedPtr    directIllum;
		Texture::SharedPtr    indirectIllum;
	} mInputTex;

	// Some internal state
	bool mNeedFboClear = true;
	bool mFilterEnabled = true;

private:
	// After resizing or creating framebuffers, make sure to initialize them
	void clearFbos(RenderContext* pCtx);

	// Encapsulate each of the passes in its own method
	void computeReprojection(RenderContext* pRenderContext);
	void computeVarianceEstimate(RenderContext* pRenderContext);
	void computeAtrousDecomposition(RenderContext* pRenderContext);
	void computeModulation(RenderContext* pRenderContext);
};
