#ifndef INTERPOLATION_MODE
#define INTERPOLATION_MODE linear
#endif

struct GBufVertexOut
{
	VertexOut base;
	INTERPOLATION_MODE float3 normalObj  : OBJECTNORMAL;
	uint instanceID : INSTANCEID;
}; 
