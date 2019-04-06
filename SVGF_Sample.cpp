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

#include "Falcor.h"
#include "../SharedUtils/RenderingPipeline.h"
#include "Passes/GBufferForSVGF.h"
#include "Passes/SVGFPass.h"
#include "Passes/GGXGlobalIllumination.h"
#include "Passes/SimpleToneMappingPass.h"

int WINAPI WinMain(_In_ HINSTANCE hInstance, _In_opt_ HINSTANCE hPrevInstance, _In_ LPSTR lpCmdLine, _In_ int nShowCmd)
{
	// Create our rendering pipeline
	RenderingPipeline *pipeline = new RenderingPipeline();

	// Next, we add passes into our rendering pipeline.  These passes contain the most relevant
	//    details for the rendering in this sample.

    // Create a G-buffer in the usual way, though the format is specific to our SVGF implementation
	pipeline->setPass(0, GBufferForSVGF::create() );

	// A global illumination pass that renders GGX-based one bounce GI into 2 output buffers
	//     (named "DirectAccum" and "IndirectAccum").  This is a fairly standard GI pass
	pipeline->setPass(1, GGXGlobalIlluminationPass::create("DirectAccum", "IndirectAccum"));

	// Apply the SVGF filter separately on the direct and indirect 1spp buffers, and save the
	//      filtered output into a buffer named "HDRColorOutput"
	pipeline->setPass(2, SVGFPass::create("DirectAccum", "IndirectAccum", "HDRColorOutput"));

	// Take the (HDR) filtered output and apply a tone mapping pass to generate the final output color.
	//      (By default, this pass applies no tonemapping, but the UI provides other options)
	pipeline->setPass(3, SimpleToneMappingPass::create("HDRColorOutput", ResourceManager::kOutputChannel));

	// Define a set of config / window parameters for our program
    SampleConfig config;
	config.windowDesc.title = "Simple sample to filter one sample per pixel, one-bounce path tracing using basic SVGF (spatiotemporal variance-guided filtering).";
	config.windowDesc.resizableWindow = false;
	config.windowDesc.width = 1920;
	config.windowDesc.height = 1200;

	// Start our program!
	RenderingPipeline::run(pipeline, config);
}
