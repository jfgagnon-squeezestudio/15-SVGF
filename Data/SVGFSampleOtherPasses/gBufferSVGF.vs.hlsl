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

#include "VertexAttrib.h"
#include "svgfGBufData.h"

// Invokes our Slang shader preprocessor to include the functionality from ShaderCommon.slang.
__import ShaderCommon;

// Invokes Slang to import the default vertex shader, it's inputs and outputs
__import DefaultVS;

// Define our main() entry point for our vertex shader
GBufVertexOut main(VertexIn vIn)
{
	GBufVertexOut vOut;
	vOut.base = defaultVS(vIn);       // Call the default Falcor vertex shader (see DefaultVS.slang)
	vOut.instanceID = vIn.instanceID; // Pass down the current instance ID for use in our G-buffer

#ifdef HAS_NORMAL
	vOut.normalObj = vIn.normal;      // Our g-buffer is storing an object-space normal, so pass that down
#else
	vOut.normalObj = 0;               //  .... Unless we don't have an object space normal.
#endif

	return vOut;
}
