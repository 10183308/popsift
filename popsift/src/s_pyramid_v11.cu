#include "s_pyramid.h"

#include "write_plane_2d.h"
#include "gauss_filter.h"
#include "clamp.h"
#include "debug_macros.h"
#include "assist.h"
#include <cuda_runtime.h>
#include <curand_mtgp32_kernel.h>
#include <device_launch_parameters.h>
#include <stdio.h>

/*************************************************************
 * V11: device side
 *************************************************************/

#define V11_EDGE_LEN 32

#define HORIZ_NO_SHARED_128x1

namespace popart {

__global__
void filter_gauss_horiz_v11_128x1( Plane2D_float src_data,
                                   Plane2D_float dst_data,
                                   int level )
{
    __shared__ float loaddata[GAUSS_SPAN + 128 + GAUSS_SPAN];

    const int src_w = src_data.getWidth();
    const int src_h = src_data.getHeight();

    int       idx    = threadIdx.x;
    const int off_x = blockIdx.x * blockDim.x + threadIdx.x;
    int       read_x;
    int       read_y = clamp( blockIdx.y, src_h );
    if( idx < GAUSS_SPAN ) {
        read_x = clamp( off_x - GAUSS_SPAN, src_w );
        loaddata[idx] = src_data.ptr(read_y)[read_x];
    } else if( idx >= 128-GAUSS_SPAN ) {
        read_x = clamp( off_x + GAUSS_SPAN, src_w );
        loaddata[idx+2*GAUSS_SPAN] = src_data.ptr(read_y)[read_x];
    }
    __syncthreads();
    read_x = clamp( off_x, src_w );
    loaddata[idx+GAUSS_SPAN] = src_data.ptr(read_y)[read_x];
    __syncthreads();

    float g;
    float val;
    float out = 0;

    for( int offset = GAUSS_SPAN; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[level*GAUSS_ALIGN+offset];
        val = loaddata[threadIdx.x+GAUSS_SPAN-offset];
        out += ( val * g );
        val = loaddata[threadIdx.x+GAUSS_SPAN+offset];
        out += ( val * g );
    }
    g  = popart::d_gauss_filter[level*GAUSS_ALIGN];
    val = loaddata[threadIdx.x+4];
    out += ( val * g );

    __syncthreads();

    if( off_x >= src_w )      return;
    if( blockIdx.y >= src_h ) return;

    dst_data.ptr(blockIdx.y)[off_x] = out;
}

__global__
void filter_gauss_horiz_v11_128x1_no_shared( Plane2D_float src_data,
                                             Plane2D_float dst_data,
                                             int level )
{
    const int src_w = src_data.getWidth();
    const int src_h = src_data.getHeight();

    const int off_x  = blockIdx.x * blockDim.x + threadIdx.x;
    int       read_x;
    const int read_y = clamp( blockIdx.y, src_h );

    if( off_x >= src_w )      return;
    if( blockIdx.y >= src_h ) return;

    float g;
    float val;
    float out = 0;

    #pragma unroll
    for( int offset = GAUSS_SPAN; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[level*GAUSS_ALIGN+offset];

        read_x = clamp( off_x - offset, src_w );
        val = src_data.ptr(read_y)[read_x];
        out += ( val * g );

        read_x = clamp( off_x + offset, src_w );
        val = src_data.ptr(read_y)[read_x];
        out += ( val * g );
    }
    g  = popart::d_gauss_filter[level*GAUSS_ALIGN];

    read_x = clamp( off_x, src_w );
    val = src_data.ptr(read_y)[read_x];
    out += ( val * g );

    dst_data.ptr(blockIdx.y)[off_x] = out;
}
#if 0
__global__
void filter_gauss_horiz_v11( Plane2D_float src_data,
                             Plane2D_float dst_data )
{
    __shared__ float loaddata[V11_EDGE_LEN][V11_RANGE + V11_EDGE_LEN + V11_RANGE];

    const int src_w = src_data.getWidth();
    const int src_h = src_data.getHeight();

    int idx     = threadIdx.x;
    int idy     = threadIdx.y;
    for( ; idx < V11_EDGE_LEN+2*V11_RANGE; idx += V11_EDGE_LEN) {
        int read_x = clamp( blockIdx.x * blockDim.x + idx - V11_RANGE, src_w );
        int read_y = clamp( blockIdx.y * blockDim.y + idy,             src_h );
        loaddata[idy][idx] = src_data.ptr(read_y)[read_x];
    }
    __syncthreads();

    float g;
    float val;
    float out = 0;

    for( int offset = V11_RANGE; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE - offset];
        val = loaddata[threadIdx.y][threadIdx.x+V11_RANGE-offset];
        out += ( val * g );
        val = loaddata[threadIdx.y][threadIdx.x+V11_RANGE+offset];
        out += ( val * g );
    }
    g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE];
    val = loaddata[threadIdx.y][threadIdx.x+V11_RANGE];
    out += ( val * g );

    idx = blockIdx.x * blockDim.x + threadIdx.x;
    idy = blockIdx.y * blockDim.y + threadIdx.y;
    if( idx >= src_w ) return;
    if( idy >= src_h ) return;

    dst_data.ptr(idy)[idx] = out;
}
#endif

__global__
void filter_gauss_horiz_v11_128x1( cudaTextureObject_t src_data,
                                   Plane2D_float       dst_data,
                                   int level )
{
    __shared__ float loaddata[GAUSS_SPAN + 128 + GAUSS_SPAN];

    const int idx   = threadIdx.x;
    const int off_x = blockIdx.x * blockDim.x + threadIdx.x;

    if( idx < GAUSS_SPAN ) {
        loaddata[idx] = tex2D<float>( src_data, off_x-GAUSS_SPAN, blockIdx.y );
    } else if( idx >= 128-GAUSS_SPAN ) {
        loaddata[idx+2*GAUSS_SPAN] = tex2D<float>( src_data, off_x+GAUSS_SPAN, blockIdx.y );
    }
    __syncthreads();
    loaddata[idx+GAUSS_SPAN] = tex2D<float>( src_data, off_x, blockIdx.y );
    __syncthreads();

    float g;
    float val;
    float out = 0;

    for( int offset = GAUSS_SPAN; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[level*GAUSS_ALIGN + offset];
        val = loaddata[threadIdx.x+GAUSS_SPAN-offset];
        out += ( val * g );
        val = loaddata[threadIdx.x+GAUSS_SPAN+offset];
        out += ( val * g );
    }
    g  = popart::d_gauss_filter[level*GAUSS_ALIGN];
    val = loaddata[threadIdx.x+GAUSS_SPAN];
    out += ( val * g );

    const int dst_w = dst_data.getWidth();
    if( off_x >= dst_w )      return;

    dst_data.ptr(blockIdx.y)[off_x] = out;
}

__global__
void filter_gauss_horiz_v11_128x1_no_shared( cudaTextureObject_t src_data,
                                             Plane2D_float       dst_data,
                                             int level )
{
    const int dst_w = dst_data.getWidth();

    const int off_x = blockIdx.x * blockDim.x + threadIdx.x;

    if( off_x >= dst_w ) return;

    float out = 0;

    #pragma unroll
    for( int offset = GAUSS_SPAN; offset>0; offset-- ) {
        const float& g  = popart::d_gauss_filter[level*GAUSS_ALIGN + offset];
        const float  v1 = tex2D<float>( src_data, off_x - offset, blockIdx.y );
        out += ( v1 * g );

        const float  v2 = tex2D<float>( src_data, off_x + offset, blockIdx.y );
        out += ( v2 * g );
    }
    const float& g  = popart::d_gauss_filter[level*GAUSS_ALIGN];
    const float v3 = tex2D<float>( src_data, off_x, blockIdx.y );
    out += ( v3 * g );

    dst_data.ptr(blockIdx.y)[off_x] = out;
}

#if 0
__global__
void filter_gauss_horiz_v11( cudaTextureObject_t src_data,
                             Plane2D_float       dst_data )
{
    int block_x = blockIdx.x * blockDim.x;
    int block_y = blockIdx.y * blockDim.y;
    int idx;
    int idy     = threadIdx.y;

    float g;
    float val;
    float out = 0;

    for( int offset = V11_RANGE; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE - offset];

        idx = threadIdx.x - offset;
        val = tex2D<float>( src_data, block_x + idx, block_y + idy );
        out += ( val * g );

        idx = threadIdx.x + offset;
        val = tex2D<float>( src_data, block_x + idx, block_y + idy );
        out += ( val * g );
    }

    g  = popart::d_gauss_filter[GAUSS_ONE_SIDE_RANGE];
    idx = threadIdx.x;
    val = tex2D<float>( src_data, block_x + idx, block_y + idy );
    out += ( val * g );

    idx = block_x+threadIdx.x;
    idy = block_y+threadIdx.y;
    const int dst_w = dst_data.getWidth();
    const int dst_h = dst_data.getHeight();
    if( idx >= dst_w ) return;
    if( idy >= dst_h ) return;

    dst_data.ptr(idy)[idx] = out;
}
#endif

__global__
void filter_gauss_horiz_v11_by_2( cudaTextureObject_t src_data,
                                  Plane2D_float       dst_data,
                                  int level )
{
    int block_x = blockIdx.x * blockDim.x;
    int block_y = blockIdx.y * blockDim.y;
    int idx;
    int idy     = threadIdx.y;

    float g;
    float val;
    float out = 0;

    for( int offset = GAUSS_SPAN; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[level*GAUSS_ALIGN + offset];

        idx = threadIdx.x - offset;
        val = tex2D<float>( src_data, 2 * ( block_x + idx ), 2 * ( block_y + idy ) );
        out += ( val * g );

        idx = threadIdx.x + offset;
        val = tex2D<float>( src_data, 2 * ( block_x + idx ), 2 * ( block_y + idy ) );
        out += ( val * g );
    }

    g  = popart::d_gauss_filter[level*GAUSS_ALIGN];
    idx = threadIdx.x;
    val = tex2D<float>( src_data, 2 * ( block_x + idx ), 2 * ( block_y + idy ) );
    out += ( val * g );

    idx = block_x+threadIdx.x;
    idy = block_y+threadIdx.y;
    const int dst_w = dst_data.getWidth();
    const int dst_h = dst_data.getHeight();
    if( idx >= dst_w ) return;
    if( idy >= dst_h ) return;

    dst_data.ptr(idy)[idx] = out;
}

    //input texture (src_data) has twize the size of dst_data.
    //the block and thread dimensions are that of dst_data.
#if 0
__global__
void downscale_by_2(Plane2D_float src_data,
                    Plane2D_float dst_data)
{
    int block_x = blockIdx.x * blockDim.x;
    int block_y = blockIdx.y * blockDim.y;
    int idx     = threadIdx.x;
    int idy     = threadIdx.y;

    const int dst_w = dst_data.getWidth();
    const int dst_h = dst_data.getHeight();
    if( idx >= dst_w ) return;
    if( idy >= dst_h ) return;

    //todo: cant do tex2d lookup in Plane2D_float array (not texture memory).
    //      Need to either use another input buffer, or change to slower global memory lookup.
    //add 0.5f to lookup coords to get interpolated values? Does it work here?
    dst_data.ptr(idy)[idx] = tex2D<float>( src_data,
                                           2 * ( block_x + idx ),
                                           2 * ( block_y + idy ));
}
#endif
__global__
void filter_gauss_vert_v11( cudaTextureObject_t src_data,
                            Plane2D_float       dst_data,
                            int level )
{
    int block_x = blockIdx.x * blockDim.x;
    int block_y = blockIdx.y * blockDim.y;
    int idx     = threadIdx.x;
    int idy;

    float g;
    float val;
    float out = 0;

    for( int offset = GAUSS_SPAN; offset>0; offset-- ) {
        g  = popart::d_gauss_filter[level*GAUSS_ALIGN + offset];

        idy = threadIdx.y - offset;
        val = tex2D<float>( src_data, block_x + idx, block_y + idy );
        out += ( val * g );

        idy = threadIdx.y + offset;
        val = tex2D<float>( src_data, block_x + idx, block_y + idy );
        out += ( val * g );
    }

    g  = popart::d_gauss_filter[level*GAUSS_ALIGN];
    idy = threadIdx.y;
    val = tex2D<float>( src_data, block_x + idx, block_y + idy );
    out += ( val * g );

    idx = block_x+threadIdx.x;
    idy = block_y+threadIdx.y;
    const int dst_w = dst_data.getWidth();
    const int dst_h = dst_data.getHeight();
    if( idx >= dst_w ) return;
    if( idy >= dst_h ) return;

    dst_data.ptr(idy)[idx] = out;
}


__global__
void make_dog( cudaTextureObject_t this_data,
               cudaTextureObject_t top_data,
               cudaSurfaceObject_t dog_data,
               int                 level )
{
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    const int idy = blockIdx.y * blockDim.y + threadIdx.y;

    const float b = tex2D<float>( this_data, idx, idy );
    const float a = tex2D<float>( top_data, idx, idy );
    const float c = a - b; // c = fabs( a - b );

    surf2DLayeredwrite( c, dog_data, idx*4, idy, level, cudaBoundaryModeZero );
}

/*************************************************************
 * V11: host side
 *************************************************************/
__host__
void Pyramid::build_v11( Image* base )
{
#if (PYRAMID_PRINT_DEBUG==1)
    cerr << "Entering " << __FUNCTION__ << " with base image "  << endl
         << "    type size         : " << base->type_size << endl
         << "    aligned byte size : " << base->a_width << "x" << base->a_height << endl
         << "    pitch size        : " << base->pitch << "x" << base->a_height << endl
         << "    original byte size: " << base->u_width << "x" << base->u_height << endl
         << "    aligned pix size  : " << base->a_width/base->type_size << "x" << base->a_height << endl
         << "    original pix size : " << base->u_width/base->type_size << "x" << base->u_height << endl;
#endif // (PYRAMID_PRINT_DEBUG==1)

#if 0
    //Creating the octaves
    for(uint32_t octave=0; octave<_num_octaves; octave++){
        const int width  = _octaves[octave].getData(0).getWidth();
        const int height = _octaves[octave].getData(0).getHeight();
        dim3 h_block( 64, 2 );
        dim3 h_grid;

        h_grid.x = (unsigned int)grid_divide( width,  h_block.x );
        h_grid.y = (unsigned int)grid_divide( height, h_block.y );

        dim3 v_block( 64, 2 );
        dim3 v_grid;
        v_grid.x = (unsigned int)grid_divide( width,  v_block.x );
        v_grid.y = (unsigned int)grid_divide( height, v_block.y );

        dim3 d_block( 32, 1 );
        dim3 d_grid;
        d_grid.x = (unsigned int)grid_divide( width,  d_block.x );
        d_grid.y = (unsigned int)grid_divide( height, d_block.y );

        if(octave==0){
            downscale_by_2<<<h_grid,h_block>>>(base->array,
                                               _octaves[octave  ].getData(0));
        }else{
            downscale_by_2<<<h_grid,h_block>>>(_octaves[octave-1].getData(0),
                                               _octaves[octave  ].getData(0));
        }

    }

    //Performing the gaussing
    for(uint32_t octave=0; octave<_num_octaves; octave++) {
        const int width  = _octaves[octave].getData(0).getWidth();
        const int height = _octaves[octave].getData(0).getHeight();
        dim3 h_block( 64, 2 );
        dim3 h_grid;

        h_grid.x = (unsigned int)grid_divide( width,  h_block.x );
        h_grid.y = (unsigned int)grid_divide( height, h_block.y );

        dim3 v_block( 64, 2 );
        dim3 v_grid;
        v_grid.x = (unsigned int)grid_divide( width,  v_block.x );
        v_grid.y = (unsigned int)grid_divide( height, v_block.y );

        dim3 d_block( 32, 1 );
        dim3 d_grid;
        d_grid.x = (unsigned int)grid_divide( width,  d_block.x );
        d_grid.y = (unsigned int)grid_divide( height, d_block.y );

        //horizontal
        //  input : _data_tex[level-1]
        //  output: getIntermediateData();
        //vertical:
        //  input : _interm_data_tex
        //  output:
        //      lvl0 : getData(level)
        //      lvl>0: getDogSurface()
        for (uint32_t level = 0; level < _levels; level++) {
            if(level == 0){
                filter_gauss_horiz_v11 <<<h_grid,h_block>>> (
                    _octaves[octave]._data_tex[level],
                    _octaves[octave].getIntermediateData() );
                filter_gauss_horiz_v11 <<<h_grid,h_block>>> (
                    _octaves[octave]._data_tex[level],
                    _octaves[octave].getIntermediateData() );
                filter_gauss_horiz_v11 <<<h_grid,h_block>>> (
                    _octaves[octave]._data_tex[level],
                    _octaves[octave].getIntermediateData() );
            }


            if( level == 0 ) {
                if( octave == 0 ) {
                    dim3 block(V11_EDGE_LEN,V11_EDGE_LEN);
                    dim3 grid((unsigned int)grid_divide( width,  V11_EDGE_LEN ),
                              (unsigned int)grid_divide( height, V11_EDGE_LEN ));

                    filter_gauss_horiz_v11 <<<grid,block>>> (
                        _octaves[octave]._data_tex[level-1],
                        _octaves[octave].getIntermediateData() );
                } else {
                    filter_gauss_horiz_v11 <<<h_grid,h_block>>> (
                        _octaves[octave-1]._data_tex[ _levels-3 ],
                        _octaves[octave].getIntermediateData( ) );
                }
            }
            else {
                filter_gauss_horiz_v11 <<<h_grid,h_block>>> (
                        _octaves[octave]._data_tex[ level-1 ],
                                _octaves[octave].getIntermediateData( ) );
            }



            if( level == 0 ) {
                filter_gauss_vert_v11 <<<v_grid,v_block>>> (
                        _octaves[octave]._interm_data_tex,
                                _octaves[octave].getData( level ) );
            }
            else {
                filter_gauss_vert_v11_dog <<<d_grid,d_block>>> (
                        _octaves[octave]._interm_data_tex,
                                _octaves[octave].getData( level ),
                                _octaves[octave]._data_tex[level-1],
                                _octaves[octave].getDogSurface( ),
                                level-1 );
            }
        }
    }

#else

    for( uint32_t octave=0; octave<_num_octaves; octave++ ) {
        for( uint32_t level=0; level<_levels; level++ ) {

            const int width  = _octaves[octave].getData(0).getWidth();
            const int height = _octaves[octave].getData(0).getHeight();

            Octave&      oct_obj   = _octaves[octave];
            cudaStream_t oct_str_0 = oct_obj.getStream(0);

            if( level == 0 ) {
                if( octave == 0 ) {
#if 0
                    dim3 block( 32, 1 );
                    dim3 grid;
                    grid.x  = grid_divide( width,  128 );
                    grid.y  = height;
                    filter_gauss_horiz_v11
                        <<<grid,block,0,oct_str_0>>>
                        ( base->array,
                          oct_obj.getIntermediateData( ) );
#else
                    dim3 block( 128, 1 );
                    dim3 grid;
                    grid.x  = grid_divide( width,  128 );
                    grid.y  = height;
#ifdef HORIZ_NO_SHARED_128x1
                    filter_gauss_horiz_v11_128x1_no_shared
                        <<<grid,block,0,oct_str_0>>>
                        ( base->array,
                          oct_obj.getIntermediateData( ),
                          level );
#else // HORIZ_NO_SHARED_128x1
                    filter_gauss_horiz_v11_128x1
                        <<<grid,block,0,oct_str_0>>>
                        ( base->array,
                          oct_obj.getIntermediateData( ),
                          level );
#endif // HORIZ_NO_SHARED_128x1
#endif
                } else {
                    dim3 h_block( 64, 2 );
                    dim3 h_grid;
                    h_grid.x = (unsigned int)grid_divide( width,  h_block.x );
                    h_grid.y = (unsigned int)grid_divide( height, h_block.y );

                    Octave& prev_oct_obj  = _octaves[octave-1];
                    cudaStreamWaitEvent( oct_str_0, prev_oct_obj.getEventGaussDone( _levels-3 ), 0 );

                    filter_gauss_horiz_v11_by_2
                        <<<h_grid,h_block,0,oct_str_0>>>
                        ( prev_oct_obj._data_tex[ _levels-3 ],
                          // _octaves[octave-1]._data_tex[ 0 ],
                          oct_obj.getIntermediateData( ),
                          level );
                }
            } else {
#if 0
                dim3 h_block( 64, 2 );
                dim3 h_grid;
                h_grid.x = (unsigned int)grid_divide( width,  h_block.x );
                h_grid.y = (unsigned int)grid_divide( height, h_block.y );

                filter_gauss_horiz_v11
                    <<<h_grid,h_block,0,oct_str_0>>>
                    ( oct_obj._data_tex[ level-1 ],
                      oct_obj.getIntermediateData( ) );
#else
                // const int width  = _octaves[octave].getData(0).getWidth();
                // const int height = _octaves[octave].getData(0).getHeight();
                dim3 block( 128, 1 );
                dim3 grid;
                grid.x  = grid_divide( width,  128 );
                grid.y  = height;
#ifdef HORIZ_NO_SHARED_128x1
                filter_gauss_horiz_v11_128x1_no_shared
                    <<<grid,block,0,oct_str_0>>>
                    ( oct_obj._data_tex[ level-1 ],
                      oct_obj.getIntermediateData( ),
                      level );
#else // HORIZ_NO_SHARED_128x1
                filter_gauss_horiz_v11_128x1
                    <<<grid,block,0,oct_str_0>>>
                    ( oct_obj._data_tex[ level-1 ],
                      oct_obj.getIntermediateData( ),
                      level );
#endif // HORIZ_NO_SHARED_128x1
#endif
            }

            if( level == 0 ) {
                dim3 v_block( 64, 2 );
                dim3 v_grid;
                v_grid.x = (unsigned int)grid_divide( width,  v_block.x );
                v_grid.y = (unsigned int)grid_divide( height, v_block.y );

                filter_gauss_vert_v11
                    <<<v_grid,v_block,0,oct_str_0>>>
                    ( oct_obj._interm_data_tex,
                      oct_obj.getData( level ),
                      level );
            } else {
                dim3 v_block( 64, 2 );
                dim3 v_grid;
                v_grid.x = (unsigned int)grid_divide( width,  v_block.x );
                v_grid.y = (unsigned int)grid_divide( height, v_block.y );

                filter_gauss_vert_v11
                    <<<v_grid,v_block,0,oct_str_0>>>
                    ( oct_obj._interm_data_tex,
                      oct_obj.getData( level ),
                      level );

                dim3 e_block( 128, 2 );
                dim3 e_grid;
                e_grid.x = grid_divide( width,  e_block.x );
                e_grid.y = grid_divide( height, e_block.y );

                make_dog
                    <<<e_grid,e_block,0,oct_str_0>>>
                    ( oct_obj._data_tex[level],
                      oct_obj._data_tex[level-1],
                      oct_obj.getDogSurface( ),
                      level-1 );
            }

            cudaEventRecord( oct_obj.getEventGaussDone( level ), oct_str_0 );
        }
    }
#endif
}

} // namespace popart

