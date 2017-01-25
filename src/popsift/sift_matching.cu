/*
* Copyright 2017, Simula Research Laboratory
*
* This Source Code Form is subject to the terms of the Mozilla Public
* License, v. 2.0. If a copy of the MPL was not distributed with this
* file, You can obtain one at http://mozilla.org/MPL/2.0/.
*/

#include <float.h>


#include "sift_matching.h"
#include "assist.h"
#include "sift_conf.h"
#include "sift_octave.h"
#include "sift_pyramid.h"
#include "sift_extremum.h"
#include "popsift.h"
#include "common/debug_macros.h"
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

namespace popsift {

__global__
void ConvertDescriptorsToU8(Descriptor* d_desc, int count, U8Descriptor* out) {
    int tid = threadIdx.x;
    for (int i = tid; i < count; i += blockDim.x) {
        for (int x = 0; x < 128; x++) {
            unsigned int tmp = d_desc[i].features[x] * 512;
            out[i].features[x] = tmp;
        }
    }
}

U8Descriptor* ConvertDescriptorsToU8(Descriptor* d_descriptors, int count)
{
    auto u8d_descriptors = popsift::cuda::malloc_devT<U8Descriptor>(count, __FILE__, __LINE__);
    int threads_per_block = 64;
    int block_count = (int)ceil(count / (float)threads_per_block);
    ConvertDescriptorsToU8<<<block_count, threads_per_block>>> (d_descriptors, count, u8d_descriptors);
    return u8d_descriptors;
}

Matching::Matching(Config& config)
 : config(config) {

}

Matching::~Matching() {

}

template<typename T>
__device__
float calc_distance_minret(const T* a, const T* b, const float* min2) {
    float sum = 0.0f;
    for (int i = 0; i < 128; i++) {
        float sub = a[i] - b[i];
        sum += sub*sub;
        if (sum > *min2) return sum;
    }
    return sum;
}

__device__ inline unsigned int swar_sub(unsigned int a, unsigned int b) {
    const unsigned int h = 0x80808080;
    return ((a | h) - (b & ~h)) ^ ((a ^ ~b) & h);
}

__device__ inline void update_sum(unsigned& sum, unsigned &d)
{
    unsigned v = d & 0xFF; d >>= 8;
    sum += v*v;
}

__device__
float calc_distance(const U8Descriptor& aa, const U8Descriptor& bb) {
    unsigned sum = 0;
#if 1
    for (int i = 0; i < 128; i++) {
        unsigned a = aa.features[i] - bb.features[i];
        sum += a*a;
    }
    return sum;
#else
    for (int i = 0; i < 32; i += 4) {
        unsigned a = *(const unsigned*)(aa.features + 4 * i);
        unsigned b = *(const unsigned*)(bb.features + 4 * i);
        unsigned d = swar_sub(a, b);
        update_sum(sum, d);
        update_sum(sum, d);
        update_sum(sum, d);
        update_sum(sum, d);
    }
    return sum;
    */
}

//~16+sec execution
__global__
void test(Descriptor* d_desc_a, int desc_a_count, Descriptor* d_desc_b, int desc_b_count, int* output) {
    int tid = threadIdx.x;
    
    for (int i = tid; i < desc_a_count; i += blockDim.x) {
        Descriptor& a = d_desc_a[i];
        float min1 = FLT_MAX, min2 = FLT_MAX;
        int min_index;

        for (int x = 0; x < desc_b_count; x++) {
            float dst = calc_distance_minret<float>(&a.features[0], &d_desc_b[x].features[0], &min2);
            //printf("%f", dst);
            if (dst < min1) {
                min2 = min1;
                min1 = dst;
                min_index = x;
            }
            else if (dst < min2) {
                min2 = dst;
            }
        }

        if (min1 / min2 < 0.64f) {
            output[i] = min_index;
        }
        else {
            output[i] = -1;
        }
    }
}



//~1.2sec execution 128x1
__global__
    void u8_test(U8Descriptor* d_desc_a, int desc_a_count, U8Descriptor* d_desc_b, int desc_b_count, int* output) {
        int tid = threadIdx.x + (blockIdx.x * blockDim.x);
        if (tid >= desc_a_count) return;

    __shared__ U8Descriptor a;
    a = d_desc_a[tid];
    float min1 = FLT_MAX, min2 = FLT_MAX;
    int min_index;
    const int cache_size = 128;
    const int skip_len = cache_size;// *2;
    __shared__ U8Descriptor cached[cache_size];

    for (int x = 0; x < desc_b_count-cache_size; x += cache_size) {
        //memcpy(cached[threadIdx.x].features, d_desc_b[threadIdx.x + x].features, sizeof(U8Descriptor));
        //cached[threadIdx.x] = d_desc_b[threadIdx.x + x];
        /*
        unsigned char* ap = &d_desc_b[x].features[0];
        unsigned char* bp = &cached[0].features[0];
        memcpy(bp + (threadIdx.x*skip_len), ap + (threadIdx.x*skip_len), sizeof(unsigned char) * skip_len);
        */
        /*
        for (int i = 0; i < cache_size; i++) {
            int dst = 0;
#if 0
            for (int s = 0; s < 128; s+=4) {
                unsigned int tmp = swar_sub(*(unsigned int*)&a.features[s], *(unsigned int*)&cached[i].features[s]);     
                #pragma unroll
                for (int k = 0; k < 4; k++) {
                    unsigned char v = (tmp >> (k * 8)) & 0xFF;
                    dst += v*v;
                }
            }
#else
            for (int s = 0; s < 128; s++) {
                unsigned char sub = a.features[s] - cached[i].features[s];
                dst += sub*sub;
            }
#endif
            if (dst < min1) {
                min2 = min1;
                min1 = dst;
                min_index = x;
            }
            else if (dst < min2) {
                min2 = dst;
            }
        }
        */
    }
    /*
    for (int x = 0; x < desc_b_count; x++) {
        float dst = calc_distance<unsigned char>(&a.features[0], &d_desc_b[x].features[0], &min2);
        if (dst < min1) {
            min2 = min1;
            min1 = dst;
            min_index = x;
        }
        else if (dst < min2) {
            min2 = dst;
        }
    }

    if (min1 / min2 < 0.64f) {
        output[tid] = min_index;
    }
    else {
        output[tid] = -1;
    }*/
}

//~3sec execution
__global__
void u8_test_shared(U8Descriptor* d_desc_a, int desc_a_count, U8Descriptor* d_desc_b, int desc_b_count, int* output) {
    int tid = threadIdx.x + (blockIdx.x * blockDim.x);
    if (tid >= desc_a_count) return;

    __shared__ U8Descriptor b[32];
    U8Descriptor desc = d_desc_a[tid];
    float min1 = FLT_MAX, min2 = FLT_MAX;
    int min_index;

    for (int x = 0; x < desc_b_count; x += 32) {
        memcpy(b[threadIdx.x].features, d_desc_b[x + threadIdx.x].features, sizeof(U8Descriptor));

        for (int i = 0; i < 32; i++) {
            float dst = calc_distance_minret<unsigned char>(desc.features, b[i].features, &min2);
            if (dst < min1) {
                min2 = min1;
                min1 = dst;
                min_index = x + i;
            }
            else if (dst < min2) {
                min2 = dst;
            }
        }
    }

    if (min1 / min2 < 0.64f) {
        output[tid] = min_index;
    }
    else {
        output[tid] = -1;
    }
}


__device__ void reduce(float* vals) {
    int tid = threadIdx.x;
    if (tid > 15) return;
    vals[tid] += vals[tid + 16];
    vals[tid] += vals[tid + 8];
    vals[tid] += vals[tid + 4];
    vals[tid] += vals[tid + 2];
    vals[tid] += vals[tid + 1];
}

//needs 32x1 blocksize ~5sec execution
__global__
void char_32thread_1desc(U8Descriptor* d_desc_a, int desc_a_count, U8Descriptor* d_desc_b, int desc_b_count, int* output) {
    int tid = threadIdx.x + (blockIdx.x * blockDim.x);
    if (tid >= desc_a_count) return;

    float min1 = FLT_MAX, min2 = FLT_MAX;
    int min_index;
    
    U8Descriptor a;
    memcpy(&a.features[threadIdx.x * 4], &d_desc_a[tid].features[threadIdx.x * 4], sizeof(unsigned char) * 4);

    __shared__ U8Descriptor b[32];
    __shared__ float sums[32];

    //could it be benefitial if different blocks started on different B's?
    for (int i = 0; i < desc_b_count; i+=32) {                   
        //memcpy(&b.features[threadIdx.x * 4], &d_desc_b[i].features[threadIdx.x * 4], sizeof(unsigned char) * 4);
        memcpy(&b[threadIdx.x].features[0], &d_desc_b[threadIdx.x + i].features[0], sizeof(U8Descriptor));


        sums[threadIdx.x] = 0.0f;
        for (int x = threadIdx.x*4; x < 128; x++) {
            float sub;// = a.features[x] - b.features[x];
            sub = sub*sub;
            sums[threadIdx.x] += sub;
        }
        __syncthreads();
        reduce(&sums[0]);
        if (threadIdx.x == 0) {
            if (sums[0] < min1) {
                min2 = min1;
                min1 = sums[0];
                min_index = i;
            }
            else if (sums[0] < min2) {
                min2 = sums[0];
            }
        }
    }
    if (threadIdx.x == 0) {
        if (min1 / min2 < 0.64f) {
            output[tid] = min_index;
        }
        else {
            output[tid] = -1;
        }
    }
}


struct MinDiff {
    float m[2];
    int idx;
};

__global__
void char_32x32(U8Descriptor* d_desc_a, int desc_a_count, 
    U8Descriptor* d_desc_b, int desc_b_count, int* output) {

    
    __shared__ U8Descriptor a[32]; //4096B
    __shared__ U8Descriptor b[32]; //4096B
    __shared__ MinDiff c[32]; //check if enough registers to remove shared

    int ltid = threadIdx.y * blockDim.x + threadIdx.x; // 0, 1023
    int gtid = ltid + blockIdx.x + (blockIdx.y*gridDim.x);
    //if (blockDim.x*blockIdx.x + threadIdx.y > desc_a_count) return; //add with ceil in blockdim on launch
    
    memcpy(&a[threadIdx.y].features[threadIdx.x * 4], &d_desc_a[blockIdx.x*blockDim.x].features[threadIdx.x * 4], sizeof(unsigned));
    memcpy(&b[threadIdx.y].features[threadIdx.x * 4], &d_desc_b[blockIdx.x*blockDim.x].features[threadIdx.x * 4], sizeof(unsigned));

    *(unsigned int*)(&a[threadIdx.y].features[threadIdx.x * 4]) = *(unsigned int*)(&d_desc_a[blockIdx.x*blockDim.x].features[threadIdx.x * 4]);
    *(unsigned int*)(&b[threadIdx.y].features[threadIdx.x * 4]) = *(unsigned int*)(&d_desc_b[blockIdx.y*blockDim.y].features[threadIdx.x * 4]);
    __syncthreads();

    //float dst = calc_distance(a[threadIdx.x], b[threadIdx.y]);
    /*
    if (dst < c[threadIdx.y].m[0]) {
        c[threadIdx.y].m[1] = c[threadIdx.y].m[0];
        c[threadIdx.y].m[0]  = dst;
        c[threadIdx.y].idx = gtid;
    }
    else if (dst < c[threadIdx.y].m[1]) {
        c[threadIdx.y].m[1] = dst;
    }
    */

    //memcpy(&a[threadIdx.y].features[threadIdx.x], &d_desc_a[]

}


__global__ 
void distance_test(int* output) {
    int tid = threadIdx.y * blockDim.x + threadIdx.x; // 0, 1023
    int gtid = tid + blockIdx.x + (blockIdx.y*gridDim.x);
    __shared__ U8Descriptor a;
    __shared__ U8Descriptor b;
    if (tid < 128) {
        a.features[tid] = tid;
        b.features[tid] = tid;
    }
    float dst = calc_distance(a, b);
    if(tid==0)
        output[gtid] = (int)dst;
    if (gtid > 14000) printf("asd");

}

std::vector<int> Matching::Match(popsift::Descriptor* d_desc_a, size_t num_desc_a,
    popsift::Descriptor* d_desc_b, size_t num_desc_b) {
        
    

    //dim3 numBlocks((int)ceil(num_desc_a / (float)(threadsPerBlock.x*threadsPerBlock.y)));
    //dim3 numBlocks((int)ceil(num_desc_a / (float)threadsPerBlock.y));
    int* d_result = popsift::cuda::malloc_devT<int>(num_desc_a, __FILE__, __LINE__);

    std::cout << "starting test\n";
#if 1

    dim3 threadsPerBlock(32, 32);
    dim3 numBlocks(num_desc_a / threadsPerBlock.x, num_desc_a / threadsPerBlock.y);
    distance_test<<<numBlocks, threadsPerBlock >>>(d_result);
#endif

#if 0
    U8Descriptor* a_U8Descriptor = ConvertDescriptorsToU8(d_desc_a, num_desc_a);
    U8Descriptor* b_U8Descriptor = ConvertDescriptorsToU8(d_desc_b, num_desc_b);
#endif

#if 0
    dim3 threadsPerBlock(32, 32);
    dim3 numBlocks(num_desc_a / threadsPerBlock.x, num_desc_b / threadsPerBlock.y); //need ceiling
    char_32x32<<<numBlocks,threadsPerBlock>>>(a_U8Descriptor, num_desc_a, b_U8Descriptor, num_desc_b, d_result);
#endif

#if 0
    dim3 threadsPerBlock(128, 1);
    dim3 numBlocks(num_desc_a / threadsPerBlock.x); //need ceiling
    u8_test<< <numBlocks, threadsPerBlock >> >(a_U8Descriptor, num_desc_a, b_U8Descriptor, num_desc_b, d_result);
#endif

    //char_32thread_1desc <<<numBlocks, threadsPerBlock >>>(a_U8Descriptor, num_desc_a, b_U8Descriptor, num_desc_b, d_result);
    std::vector<int> h_result(num_desc_a);

    //cudaMemcpyAsync(h_result.data(), d_result, num_desc_a * sizeof(int), cudaMemcpyDeviceToHost);
    cudaDeviceSynchronize();
    std::cout << "test done";
    
    
    return h_result;
}

}
