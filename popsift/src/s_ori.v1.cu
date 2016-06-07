#include "sift_pyramid.h"
#include "sift_constants.h"
#include "s_gradiant.h"
#include "debug_macros.h"

#include <math.h>
#include <stdio.h>
#include <inttypes.h>

using namespace popart;

/*************************************************************
 * V1: device side
 *************************************************************/

__device__
inline float compute_angle( int bin, float hc, float hn, float hp )
{
    /* interpolate */
    float di = bin + 0.5f * (hn - hp) / (hc+hc-hn-hp);

    /* clamp */
    di = (di < 0) ? 
            (di + ORI_NBINS) : 
            ((di >= ORI_NBINS) ? (di - ORI_NBINS) : (di));

    float th = __fdividef( M_PI2 * di, ORI_NBINS ) - M_PI;
    // float th = ((M_PI2 * di) / ORI_NBINS);
    return th;
}

/*
 * Compute the keypoint orientations for each extremum
 * using 16 threads for each of them.
 */
__global__
void compute_keypoint_orientations_v1( Extremum*     extremum,
                                       int*          extrema_counter,
                                       Plane2D_float layer )
{
    uint32_t w   = layer.getWidth();
    uint32_t h   = layer.getHeight();

    // if( threadIdx.y >= mgmt->getCounter() ) return;

    Extremum* ext = &extremum[blockIdx.x];

    float hist[ORI_NBINS];
    for (int i = 0; i < ORI_NBINS; i++) hist[i] = 0.0f;

    /* keypoint fractional geometry */
    const float x    = ext->xpos;
    const float y    = ext->ypos;
    const float sig  = ext->sigma;

    /* orientation histogram radius */
    float  sigw = ORI_WINFACTOR * sig;
    int32_t rad  = (int)rintf((3.0f * sigw));

    float factor = __fdividef( -0.5f, (sigw * sigw) );
    int sq_thres = rad * rad;
    int32_t xmin = max(1,     (int32_t)floor(x - rad));
    int32_t xmax = min(w - 2, (int32_t)floor(x + rad));
    int32_t ymin = max(1,     (int32_t)floor(y - rad));
    int32_t ymax = min(h - 2, (int32_t)floor(y + rad));

    int wx = xmax - xmin + 1;
    int hy = ymax - ymin + 1;
    int loops = wx * hy;

    for(int i = threadIdx.x; i < loops; i+=ORI_V1_NUM_THREADS)
    {
        int yy = i / wx + ymin;
        int xx = i % wx + xmin;

        float grad;
        float theta;
        get_gradiant( grad,
                      theta,
                      xx,
                      yy,
                      layer );

        float dx = xx - x;
        float dy = yy - y;

        int sq_dist  = dx * dx + dy * dy;
        if (sq_dist <= sq_thres) {
            float weight = grad * expf(sq_dist * factor);

            int bidx = (int)rintf( __fdividef( ORI_NBINS * (theta + M_PI), M_PI2 ) );
            // int bidx = (int)roundf( __fdividef( ORI_NBINS * (theta + M_PI), M_PI2 ) );

            if( bidx > ORI_NBINS ) {
                printf("Crashing: bin %d theta %f :-)\n", bidx, theta);
            }

            bidx = (bidx == ORI_NBINS) ? 0 : bidx;

            hist[bidx] += weight;
        }
    }

    /* reduction here */
    for (int i = 0; i < ORI_NBINS; i++) {
        hist[i] += __shfl_down( hist[i], 8 );
        hist[i] += __shfl_down( hist[i], 4 );
        hist[i] += __shfl_down( hist[i], 2 );
        hist[i] += __shfl_down( hist[i], 1 );
        hist[i]  = __shfl( hist[i], 0 );
    }


    if(threadIdx.x != 0) return;

    for( int iter = 0; iter < 2; iter++ ) {
        float first = hist[0];
        float prev = hist[(ORI_NBINS - 1)];

        int bin;
        //0,35
        for( bin = 0; bin < ORI_NBINS - 1; bin++ ) {
            float temp = hist[bin];
            hist[bin] = 0.25f * prev + 0.5f * hist[bin] + 0.25f * hist[bin + 1];
            prev = temp;
        }

        hist[bin] = 0.25f * prev + 0.5f * hist[bin] + 0.25f * first;
        //z vprintf("val: %f, indx: %d\n", hist[bin], bin);
    }
	
    /* find histogram maximum */
    float maxh = NINF;
    int binh = 0;
    for (int bin = 0; bin < ORI_NBINS; bin++) {
        // maxh = fmaxf(maxh, hist[bin]);
        if (hist[bin] > maxh) {
            maxh = hist[bin];
            binh = bin;
        }
    }

    {
        float hc = hist[binh];
        float hn = hist[((binh + 1 + ORI_NBINS) % ORI_NBINS)];
        float hp = hist[((binh - 1 + ORI_NBINS) % ORI_NBINS)];
        float th = compute_angle(binh, hc, hn, hp);

#ifdef DEBUG_SEARCH_FOR_NANS
        if( isnan(th) ) {
            ext->invalid |= ANGLE_IS_NAN;
        }
#endif // DEBUG_SEARCH_FOR_NANS

        ext->orientation = th;
    }

    /* find other peaks, boundary of 80% of max */
    int nangles = 1;

    for (int numloops = 1; numloops < ORI_NBINS; numloops++) {
        int bin = (binh + numloops) % ORI_NBINS;

        float hc = hist[bin];
        float hn = hist[((bin + 1 + ORI_NBINS) % ORI_NBINS)];
        float hp = hist[((bin - 1 + ORI_NBINS) % ORI_NBINS)];

        /* find if a peak */
        if (hc >= (0.8f * maxh) && hc > hn && hc > hp) {
            int idx = atomicAdd( extrema_counter, 1 );
            if( idx >= d_max_orientations ) break;

            float th = compute_angle(bin, hc, hn, hp);

            ext = &extremum[idx];
            ext->xpos = x;
            ext->ypos = y;
            ext->sigma = sig;
            ext->orientation = th;
#ifdef DEBUG_SEARCH_FOR_NANS
            ext->invalid = 0;
#endif // DEBUG_SEARCH_FOR_NANS

            nangles++;
            if (nangles > 2) break;
        }
    }
}

/*
 * Compute the keypoint orientations for each extremum
 * using 16 threads for each of them.
 * direct curve fitting approach
 */
__global__
void compute_keypoint_orientations_v2( Extremum*     extremum,
                                       int*          extrema_counter,
                                       Plane2D_float layer,
                                       int*          d_number_of_blocks,
                                       int           number_of_blocks )
{
#ifdef DEBUG_SEARCH_FOR_NANS
    int debug_invalid = 0;
#endif // DEBUG_SEARCH_FOR_NANS

    uint32_t w   = layer.getWidth();
    uint32_t h   = layer.getHeight();

    // if( threadIdx.y >= mgmt->getCounter() ) return;

    Extremum* ext = &extremum[blockIdx.x];

    float hist[ORI_NBINS];
    for (int i = 0; i < ORI_NBINS; i++) hist[i] = 0.0f;

    /* keypoint fractional geometry */
    const float x    = ext->xpos;
    const float y    = ext->ypos;
    const float sig  = ext->sigma;

    /* orientation histogram radius */
    float  sigw = ORI_WINFACTOR * sig;
    int32_t rad  = (int)rintf((3.0f * sigw));

    float factor = __fdividef( -0.5f, (sigw * sigw) );
    int sq_thres  = rad * rad;
    int32_t xmin = max(1,     (int32_t)floor(x - rad));
    int32_t xmax = min(w - 2, (int32_t)floor(x + rad));
    int32_t ymin = max(1,     (int32_t)floor(y - rad));
    int32_t ymax = min(h - 2, (int32_t)floor(y + rad));

    int wx = xmax - xmin + 1;
    int hy = ymax - ymin + 1;
    int loops = wx * hy;

    for(int i = threadIdx.x; i < loops; i+=ORI_V1_NUM_THREADS)
    {
        int yy = i / wx + ymin;
        int xx = i % wx + xmin;

        float grad;
        float theta;
        get_gradiant( grad,
                      theta,
                      xx,
                      yy,
                      layer );

        float dx = xx - x;
        float dy = yy - y;

        int sq_dist  = dx * dx + dy * dy;
        if (sq_dist <= sq_thres) {
            float weight = grad * expf(sq_dist * factor);

            int bidx = (int)rintf( __fdividef( ORI_NBINS * (theta + M_PI), M_PI2 ) );
            // int bidx = (int)roundf( __fdividef( ORI_NBINS * (theta + M_PI), M_PI2 ) );

            if( bidx > ORI_NBINS ) {
                printf("Crashing: bin %d theta %f :-)\n", bidx, theta);
            }

            bidx = (bidx == ORI_NBINS) ? 0 : bidx;

            hist[bidx] += weight;
        }
    }

    /* reduction here */
    for (int i = 0; i < ORI_NBINS; i++) {
        hist[i] += __shfl_down( hist[i], 8 );
        hist[i] += __shfl_down( hist[i], 4 );
        hist[i] += __shfl_down( hist[i], 2 );
        hist[i] += __shfl_down( hist[i], 1 );
        hist[i]  = __shfl( hist[i], 0 );
    }


    if(threadIdx.x != 0) return;

    float xcoord[ORI_NBINS];
    float yval[ORI_NBINS];

    int   maxbin[3];
    float y_max[3];

    #pragma unroll
    for( int i=0; i<3; i++ ) {
        maxbin[i] = 0;
        y_max[i] = -INFINITY;
    }

    for(int bin = 0; bin < ORI_NBINS; bin++) {
        int prev = bin - 1;
        if( prev < 0 ) prev = ORI_NBINS - 1;
        int next = bin + 1;
        if( next == ORI_NBINS ) next = 0;

        if( hist[bin] > max( hist[prev], hist[next] ) ) {
            const float num = 3.0f * hist[prev] - 4.0f * hist[bin] + hist[next];
            const float denB = 2.0f * ( hist[prev] - 2.0f * hist[bin] + hist[next] );
#ifdef DEBUG_SEARCH_FOR_NANS
            if( denB == 0 ) debug_invalid = ZERO_HISTOGRAM;
#endif // DEBUG_SEARCH_FOR_NANS

            float newbin = __fdividef( num, denB ); // * M_PI/18.0f; // * 10.0f;
            if( newbin >= 0 && newbin <= 2 ) {
                xcoord[bin] = prev + newbin;
                yval[bin]   = -(num*num) / (4.0f * denB) + hist[prev];

                if( yval[bin] > y_max[0] ) {
                    y_max[2]  = y_max[1];
                    y_max[1]  = y_max[0];
                    y_max[0]  = yval[bin];
                    maxbin[2] = maxbin[1];
                    maxbin[1] = maxbin[0];
                    maxbin[0] = bin;
                }
            }
        }
    }

    float th = __fdividef(M_PI2 * xcoord[maxbin[0]], ORI_NBINS) - M_PI;

    ext->orientation = th;
#ifdef DEBUG_SEARCH_FOR_NANS
    ext->invalid     = debug_invalid;
#endif // DEBUG_SEARCH_FOR_NANS

    for( int i=1; i<=2; i++ ) {
        if( y_max[i] < -1000.0f ) break; // this is a random number: no orientation can be this small

        if( y_max[i] < 0.8f * y_max[0] ) break;

        int idx = atomicAdd( extrema_counter, 1 );
        if( idx >= d_max_orientations ) break;

        float th = __fdividef(M_PI2 * xcoord[maxbin[i]], ORI_NBINS) - M_PI;

        ext = &extremum[idx];
        ext->xpos = x;
        ext->ypos = y;
        ext->sigma = sig;
        ext->orientation = th;
#ifdef DEBUG_SEARCH_FOR_NANS
        ext->invalid = debug_invalid;
#endif // DEBUG_SEARCH_FOR_NANS
    }

    __syncthreads();

    if( threadIdx.x == 0 && threadIdx.y == 0 ) {
        int ct = atomicAdd( d_number_of_blocks, 1 );
        if( ct >= number_of_blocks-1 ) {
            int num_ext = atomicMin( extrema_counter, d_max_orientations );
        }
    }

}

/*************************************************************
 * V4: host side
 *************************************************************/
#ifdef USE_DYNAMIC_PARALLELISM // defined in_s_pyramid.h

__global__
void orientation_starter_v1( Extremum*     extremum,
                             int*          extrema_counter,
                             Plane2D_float layer )
{
    dim3 block;
    dim3 grid;
    grid.x  = *extrema_counter;
    block.x = ORI_V1_NUM_THREADS;

    if( grid.x != 0 ) {
        compute_keypoint_orientations_v1
            <<<grid,block>>>
            ( extremum,
              extrema_counter,
              layer );
    }
}

__global__
void orientation_starter_v2( Extremum*     extremum,
                             int*          extrema_counter,
                             Plane2D_float layer,
                             int*          d_number_of_blocks )
{
    dim3 block;
    dim3 grid;
    grid.x  = *extrema_counter;
    block.x = ORI_V1_NUM_THREADS;

    if( grid.x != 0 ) {
        compute_keypoint_orientations_v2
            <<<grid,block>>>
            ( extremum,
              extrema_counter,
              layer,
              d_number_of_blocks,
              grid.x * grid.y );
    }
}

__host__
void Pyramid::orientation_v1( )
{
    for( int octave=0; octave<_num_octaves; octave++ ) {
        Octave&      oct_obj = _octaves[octave];

        int*  orientation_num_blocks = oct_obj.getNumberOfOriBlocks( );

        for( int level=1; level<_levels-2; level++ ) {
            cudaStream_t oct_str = oct_obj.getStream(level+2);

            int* extrema_counters = oct_obj.getExtremaMgmtD( );
            int* extrema_counter  = &extrema_counters[level];
            if( _bemap_orientation_mode ) {
                orientation_starter_v1
                    <<<1,1,0,oct_str>>>
                    ( oct_obj.getExtrema( level ),
                      extrema_counter,
                      oct_obj.getData( level ) );
            }  else {
                int*  num_blocks = &orientation_num_blocks[level];

                orientation_starter_v2
                    <<<1,1,0,oct_str>>>
                    ( oct_obj.getExtrema( level ),
                      extrema_counter,
                      oct_obj.getData( level ),
                      num_blocks );
            }
        }
    }
}

#else // not USE_DYNAMIC_PARALLELISM

__global__
void orientation_starter_v1( Extremum*,
                             int*,
                             Plane2D_float,
                             int* )
{
    /* dummy to make the linker happy */
}

__host__
void Pyramid::orientation_v1( )
{
    for( int octave=0; octave<_num_octaves; octave++ ) {
        Octave&      oct_obj = _octaves[octave];

        for( int level=3; level<_levels; level++ ) {
            cudaStreamSynchronize( oct_obj.getStream(level) );
        }

        oct_obj.readExtremaCount( );
        cudaDeviceSynchronize( );

        int* h_num_extrema = oct_obj.getExtremaMgmtH();
        int* d_num_extrema = oct_obj.getExtremaMgmtD();
        int* orientation_num_blocks = oct_obj.getNumberOfOriBlocks( );

        for( int level=1; level<_levels-2; level++ ) {
            cudaStream_t oct_str = oct_obj.getStream(level+2);

            dim3 block;
            dim3 grid;
            grid.x  = h_num_extrema[level];
            block.x = ORI_V1_NUM_THREADS;
            if( grid.x != 0 ) {
                if( _bemap_orientation_mode ) {
                    compute_keypoint_orientations_v1
                        <<<grid,block,0,oct_str>>>
                        ( oct_obj.getExtrema( level ),
                          &d_num_extrema[level],
                          oct_obj.getData( level ) );
                } else {
                    compute_keypoint_orientations_v2
                        <<<grid,block,0,oct_str>>>
                        ( oct_obj.getExtrema( level ),
                          &d_num_extrema[level],
                          oct_obj.getData( level ),
                          &orientation_num_blocks[level],
                          grid.x * grid.y );
                }
            }
        }
    }
}
#endif // not USE_DYNAMIC_PARALLELISM

