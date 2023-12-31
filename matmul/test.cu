#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <time.h>
#include <cuda_runtime.h>
#include <cuda.h>
#include <iostream>

#define A(i,j) A[(i) + (j)*lda]
#define B(i,j) B[(i) + (j)*ldb]
#define C(i,j) C[(i) + (j)*ldc]
#define sa7(i,j) sa7[((j)<<6) + (i)]
#define sb7(i,j) sb7[((j)<<6) + (i)]
#define MS_7 64
#define NS_7 64
#define KS_7 16
#define M 8192
#define N 8192
#define K 1024
// 分块大小
#define BM 64
#define BN 64
#define BK 16
// #define A(i,j) A[(i) + (j)*lda]
// #define B(i,j) B[(i) + (j)*ldb]
// #define C(i,j) C[(i) + (j)*ldc]
#define IDX2C(i, j, ld) ((j) * (ld) + (i)) // columb-major
//v1 += v2 * s3, vector scaling
#define vscal(v1, v2, s3)\
    v1.x+=v2.x*s3;\
    v1.y+=v2.y*s3;\
    v1.z+=v2.z*s3;\
    v1.w+=v2.w*s3;
//v1 = alpha * v2 + beta * v3, simd fma
#define simd_axpby(v1, alpha, v2, beta, v3)\
    v1.x=alpha*v2.x+beta*v3.x;\
    v1.y=alpha*v2.y+beta*v3.y;\
    v1.z=alpha*v2.z+beta*v3.z;\
    v1.w=alpha*v2.w+beta*v3.w;
#define vload(v1,addr)\
    v1 = *((float4 *)(addr));
#define vstore(addr,v1)\
    *((float4 *)(addr)) = v1;
#include<stdio.h>
#include<stdlib.h>
#define A(i,j) A[(i) + (j)*lda]
#define B(i,j) B[(i) + (j)*ldb]
#define ptr_A(i,j) ptr_A[(i) + (j)*lda]
#define ptr_B(i,j) ptr_B[(i) + (j)*ldb]
#define C(i,j) C[(i) + (j)*ldc]
#define sa10(i,j) sa10[((j)<<7) + (i)]
#define sb10(i,j) sb10[((j)<<7) + (i)]
#define MS_10 128
#define NS_10 128
#define KS_10 8
//v1 += v2 * s3, vector scaling
#define vscal(v1, v2, s3)\
    v1.x+=v2.x*s3;\
    v1.y+=v2.y*s3;\
    v1.z+=v2.z*s3;\
    v1.w+=v2.w*s3;
//v1 = alpha * v2 + beta * v3, simd fma
#define simd_axpby(v1, alpha, v2, beta, v3)\
    v1.x=alpha*v2.x+beta*v3.x;\
    v1.y=alpha*v2.y+beta*v3.y;\
    v1.z=alpha*v2.z+beta*v3.z;\
    v1.w=alpha*v2.w+beta*v3.w;
#define vload(v1,addr)\
    v1 = *((float4 *)(addr));
#define vstore(addr,v1)\
    *((float4 *)(addr)) = v1;
// cache blocking version, without register-level data re-use
// with memory coelascing on shared memory
// more workloads per thread. 8x8 micro kernel.
// adopt vetorized load/store
__global__ void naive_matmul(const int m,const int n,const int k,const float alpha, const float *A, const float *B, const float beta, float* C)
{
    int tx = threadIdx.x, ty = threadIdx.y;
    int bx = blockIdx.x, by = blockIdx.y;
    A = &A[IDX2C(bx<<5,0,m)]; // blockdim(32,32)
    B = &B[IDX2C(0,by<<5,k)];
    C = &C[IDX2C(bx<<5,by<<5,m)];
    float sum = 0.0;
    for (int i = 0; i < k; i++){
        sum += A[IDX2C(tx,i,m)] * B[IDX2C(i,ty,k)];
    }
    C[IDX2C(tx,ty,m)] = alpha * sum + beta * C[IDX2C(tx,ty,m)];
}
// cache blocking version, without register-level data re-use
// with memory coelascing on shared memory
// more workloads per thread. 4x4 micro kernel.
// adopt vetorized load/store
// __global__  __launch_bounds__(256)
__global__ void mysgemm_v7(int m, int n, int k, float alpha, float* A, float* B, float beta, float* C)
{
    int lda = M, ldb = K, ldc = M;
    int tx = threadIdx.x;
    int bx = blockIdx.x, by = blockIdx.y;
    int row_a = (tx&15)<<2, col_a = tx>>4;
    int row_b = (tx&3)<<2, col_b = tx>>2;
    int col_c = col_a<<2;
    int lda16 = lda<<4;
    A = &A((bx<<6),0); // 一个block256线程 解决64*64个元素
    B = &B(0,(by<<6));
    C = &C((bx<<6),(by<<6));//the TB size is 64.
    __shared__ float sa7[1024];
    __shared__ float sb7[1024];
    float4 Av, Bv, Cv[4], Cres[4];
    memset(Cres, 0, sizeof(Cres)); //
    for (int k_count = 0; k_count<K; k_count+=KS_7){
        vload(Av, &A[IDX2C(row_a, col_a, lda)])
        vload(Bv, &B(row_b, col_b))
        ((float4 *)sa7)[tx] = Av;
        sb7(col_b,row_b)=Bv.x;
        sb7(col_b,row_b+1)=Bv.y;
        sb7(col_b,row_b+2)=Bv.z;
        sb7(col_b,row_b+3)=Bv.w;
        A+=lda16;B+=16;
        __syncthreads();
        #pragma unroll
        for (int inner_k_count=0;inner_k_count<KS_7;inner_k_count++){
            vload(Av, &sa7[IDX2C(row_a, inner_k_count, BM)])
            vload(Bv, &sb7[IDX2C(col_c, inner_k_count, BM)])
            // vload(Av, &sa7(row_a,inner_k_count))
            // vload(Bv, &sb7(col_c,inner_k_count))
            vscal(Cres[0], Av, Bv.x)
            vscal(Cres[1], Av, Bv.y)
            vscal(Cres[2], Av, Bv.z)
            vscal(Cres[3], Av, Bv.w)
        }
        __syncthreads();
    }
    vload(Cv[0], &C[IDX2C(row_a,col_c,m)])
    vload(Cv[1], &C[IDX2C(row_a,col_c+1,m)])
    vload(Cv[2], &C[IDX2C(row_a,col_c+2,m)])
    vload(Cv[3], &C[IDX2C(row_a,col_c+3,m)]) // 向量化读
    simd_axpby(Cres[0],alpha,Cres[0],beta,Cv[0])
    simd_axpby(Cres[1],alpha,Cres[1],beta,Cv[1])
    simd_axpby(Cres[2],alpha,Cres[2],beta,Cv[2])
    simd_axpby(Cres[3],alpha,Cres[3],beta,Cv[3])

    vstore(&C[IDX2C(row_a,col_c, m)], Cres[0])
    vstore(&C[IDX2C(row_a,col_c + 1, m)], Cres[1])
    vstore(&C[IDX2C(row_a,col_c + 2, m)], Cres[2])
    vstore(&C[IDX2C(row_a,col_c + 3, m)], Cres[3])  // 向量化写
}

// __global__  __launch_bounds__(256)
__global__ void mysgemm_v10(int m, int n, int k, float alpha, float* A, float* B, float beta, float* C){
    int lda = M, ldb = K, ldc = M;
    int tx = threadIdx.x;
    int bx = blockIdx.x, by = blockIdx.y;
    int warp_id = tx>>5;
    int lane_id = tx&31;
    int warp_row = warp_id & 3, warp_col = warp_id >> 2;
    int row_w = lane_id&3, col_w = lane_id>>2;
    int row_b = (tx&1)<<2, col_b = tx>>1;
    int lda8 = lda<<3;
    int row_c = (warp_row<<5) + (row_w<<3), col_c = (warp_col<<6) + (col_w<<3);
    int row_a = (tx&31)<<2, col_a = tx>>5;
    int K_upper = K>>3;
    A = &A((bx<<7),0);
    B = &B(0,(by<<7));
    C = &C((bx<<7),(by<<7));//the TB size is 128.
    __shared__ float sa10[1024];
    __shared__ float sb10[1024];
    float4 Av1[2], Av2[2], Bv1[2], Bv2[2], Cv[16], Cres[16];
    float4 pref_Av, pref_Bv;
    float* ptr_A, *ptr_B;
    memset(Cres, 0, sizeof(Cres));//clear registers
    vload(pref_Av, &A(row_a,col_a))
    vload(pref_Bv, &B(row_b,col_b))
    ((float4 *)sa10)[tx] = pref_Av;
    sb10(col_b,row_b)=pref_Bv.x;
    sb10(col_b,row_b+1)=pref_Bv.y;
    sb10(col_b,row_b+2)=pref_Bv.z;
    sb10(col_b,row_b+3)=pref_Bv.w;
    __syncthreads();
    vload(Av1[0], &sa10(row_c,0))
    vload(Av2[0], &sa10(row_c+4,0))
    vload(Bv1[0], &sb10(col_c,0))
    vload(Bv2[0], &sb10(col_c+4,0))
    for (int k_count = 0; k_count<K_upper; k_count++){
        /*packing A and B into shared memory*/
        int inc = (k_count+1)%K_upper;
        ptr_A = A + inc * lda8;
        ptr_B = B + inc * 8;
        vload(pref_Av, &ptr_A(row_a,col_a))
        vload(pref_Bv, &ptr_B(row_b,col_b))
        #pragma unroll
        for (int inner_k_count=0;inner_k_count<KS_10;inner_k_count++){
            int next_inner_k_count = (inner_k_count+1)&7;
            vload(Av1[(inner_k_count+1)&1], &sa10(row_c,next_inner_k_count))
            vload(Av2[(inner_k_count+1)&1], &sa10(row_c+4,next_inner_k_count))
            vload(Bv1[(inner_k_count+1)&1], &sb10(col_c,next_inner_k_count))
            vload(Bv2[(inner_k_count+1)&1], &sb10(col_c+4,next_inner_k_count))
            vscal(Cres[0], Av1[(inner_k_count)&1], Bv1[(inner_k_count)&1].x)
            vscal(Cres[1], Av2[(inner_k_count)&1], Bv1[(inner_k_count)&1].x)
            vscal(Cres[2], Av1[(inner_k_count)&1], Bv1[(inner_k_count)&1].y)
            vscal(Cres[3], Av2[(inner_k_count)&1], Bv1[(inner_k_count)&1].y)
            vscal(Cres[4], Av1[(inner_k_count)&1], Bv1[(inner_k_count)&1].z)
            vscal(Cres[5], Av2[(inner_k_count)&1], Bv1[(inner_k_count)&1].z)
            vscal(Cres[6], Av1[(inner_k_count)&1], Bv1[(inner_k_count)&1].w)
            vscal(Cres[7], Av2[(inner_k_count)&1], Bv1[(inner_k_count)&1].w)
            vscal(Cres[8], Av1[(inner_k_count)&1], Bv2[(inner_k_count)&1].x)
            vscal(Cres[9], Av2[(inner_k_count)&1], Bv2[(inner_k_count)&1].x)
            vscal(Cres[10], Av1[(inner_k_count)&1], Bv2[(inner_k_count)&1].y)
            vscal(Cres[11], Av2[(inner_k_count)&1], Bv2[(inner_k_count)&1].y)
            vscal(Cres[12], Av1[(inner_k_count)&1], Bv2[(inner_k_count)&1].z)
            vscal(Cres[13], Av2[(inner_k_count)&1], Bv2[(inner_k_count)&1].z)
            vscal(Cres[14], Av1[(inner_k_count)&1], Bv2[(inner_k_count)&1].w)
            vscal(Cres[15], Av2[(inner_k_count)&1], Bv2[(inner_k_count)&1].w)
        }
        __syncthreads();
        ((float4 *)sa10)[tx] = pref_Av;
        sb10(col_b,row_b)=pref_Bv.x;
        sb10(col_b,row_b+1)=pref_Bv.y;
        sb10(col_b,row_b+2)=pref_Bv.z;
        sb10(col_b,row_b+3)=pref_Bv.w;
        __syncthreads();
        vload(Av1[0], &sa10(row_c,0))
        vload(Av2[0], &sa10(row_c+4,0))
        vload(Bv1[0], &sb10(col_c,0))
        vload(Bv2[0], &sb10(col_c+4,0))
    }
    vload(Cv[0], &C(row_c,col_c))
    vload(Cv[1], &C(row_c+4,col_c))
    vload(Cv[2], &C(row_c,col_c+1))
    vload(Cv[3], &C(row_c+4,col_c+1))
    vload(Cv[4], &C(row_c,col_c+2))
    vload(Cv[5], &C(row_c+4,col_c+2))
    vload(Cv[6], &C(row_c,col_c+3))
    vload(Cv[7], &C(row_c+4,col_c+3))
    vload(Cv[8], &C(row_c,col_c+4))
    vload(Cv[9], &C(row_c+4,col_c+4))
    vload(Cv[10], &C(row_c,col_c+5))
    vload(Cv[11], &C(row_c+4,col_c+5))
    vload(Cv[12], &C(row_c,col_c+6))
    vload(Cv[13], &C(row_c+4,col_c+6))
    vload(Cv[14], &C(row_c,col_c+7))
    vload(Cv[15], &C(row_c+4,col_c+7))
    
    simd_axpby(Cres[0],alpha,Cres[0],beta,Cv[0])
    simd_axpby(Cres[1],alpha,Cres[1],beta,Cv[1])
    simd_axpby(Cres[2],alpha,Cres[2],beta,Cv[2])
    simd_axpby(Cres[3],alpha,Cres[3],beta,Cv[3])

    simd_axpby(Cres[4],alpha,Cres[4],beta,Cv[4])
    simd_axpby(Cres[5],alpha,Cres[5],beta,Cv[5])
    simd_axpby(Cres[6],alpha,Cres[6],beta,Cv[6])
    simd_axpby(Cres[7],alpha,Cres[7],beta,Cv[7])

    simd_axpby(Cres[8],alpha,Cres[8],beta,Cv[8])
    simd_axpby(Cres[9],alpha,Cres[9],beta,Cv[9])
    simd_axpby(Cres[10],alpha,Cres[10],beta,Cv[10])
    simd_axpby(Cres[11],alpha,Cres[11],beta,Cv[11])

    simd_axpby(Cres[12],alpha,Cres[12],beta,Cv[12])
    simd_axpby(Cres[13],alpha,Cres[13],beta,Cv[13])
    simd_axpby(Cres[14],alpha,Cres[14],beta,Cv[14])
    simd_axpby(Cres[15],alpha,Cres[15],beta,Cv[15])

    vstore(&C(row_c,col_c), Cres[0])
    vstore(&C(row_c+4,col_c), Cres[1])
    vstore(&C(row_c,col_c+1), Cres[2])
    vstore(&C(row_c+4,col_c+1), Cres[3])
    vstore(&C(row_c,col_c+2), Cres[4])
    vstore(&C(row_c+4,col_c+2), Cres[5])
    vstore(&C(row_c,col_c+3), Cres[6])
    vstore(&C(row_c+4,col_c+3), Cres[7])
    vstore(&C(row_c,col_c+4), Cres[8])
    vstore(&C(row_c+4,col_c+4), Cres[9])
    vstore(&C(row_c,col_c+5), Cres[10])
    vstore(&C(row_c+4,col_c+5), Cres[11])
    vstore(&C(row_c,col_c+6), Cres[12])
    vstore(&C(row_c+4,col_c+6), Cres[13])
    vstore(&C(row_c,col_c+7), Cres[14])
    vstore(&C(row_c+4,col_c+7), Cres[15])
}
void gpuSgemm(int m, int n, int k, const float *alpha, 
    const float *A, const float *B, const float *beta, float *C) {
        int blocksize = 256;
        // int GridSize = ceil(sqrt((N+bs-1.) / bs));
        // int GridSize = ceil((M*N+blocksize-1.) / blocksize);
        int gridx = floor(M/BM);
        int gridy = floor(N/BN);
        dim3 Grid(gridx, gridy); //
        dim3 Block(256); // 32 * 32 = 1024  
        //malloc on device
        float *devPtrA, *devPtrB, *devPtrC,*devPtrD;
        cudaMalloc((void**)&devPtrA, sizeof(float) * m * k);
        cudaMalloc((void**)&devPtrB, sizeof(float) * k * n);
        cudaMalloc((void**)&devPtrC, sizeof(float) * m * n);
        cudaMalloc((void**)&devPtrD, sizeof(float) * m * n);
        //copy A and B to device
        cudaMemcpy(devPtrA, A, m * k * sizeof(float), cudaMemcpyHostToDevice);
        cudaMemcpy(devPtrB, B, k * n * sizeof(float), cudaMemcpyHostToDevice);
        cudaEvent_t start, stop;
        cudaEventCreate(&start);
        cudaEventCreate(&stop);
        cudaEventRecord(start);
// ------------------------------------------------------------------------------------
        mysgemm_v10<<<Grid,Block>>>(m,n,k,*alpha,devPtrA,devPtrB,*beta,devPtrC);
        cudaEventRecord(stop);
        cudaEventSynchronize(stop);
    
        float milliseconds = 0;
        cudaEventElapsedTime(&milliseconds, start, stop);
        printf("gpu with gemm_shared_v2 kernel time:%f ms\n",milliseconds);
        float* matrix_out_cpu=(float*)malloc(sizeof(float) * M * N);
        float* matrix_out_gpu=(float*)malloc(sizeof(float) * M * N);
        cudaMemcpy(matrix_out_cpu, devPtrC, m * n * sizeof(float), cudaMemcpyDeviceToHost);
        dim3 Grid_n(M/32, N/32); //
        dim3 Block_n(32,32); // 32 * 32 = 1024  
        naive_matmul<<<Grid_n,Block_n>>>(m,n,k,*alpha,devPtrA,devPtrB,*beta,devPtrD);
        cudaMemcpy(matrix_out_gpu, devPtrD, m * n * sizeof(float), cudaMemcpyDeviceToHost);

        float EPSILON = 0.01;
        // check result                                             
        printf("check\n");
        for (int i = 0; i < M * N; ++i) {
            float error = (matrix_out_cpu[i] - matrix_out_gpu[i]) 
                / matrix_out_gpu[i];
            if (error < -EPSILON || error > EPSILON)
                printf("wrong, %f, %f, %f\n", matrix_out_cpu[i], matrix_out_gpu[i], 
                    error);
        }
        printf("right\n");

        //release memory on device
        cudaFree(devPtrA);
        cudaFree(devPtrB);
        cudaFree(devPtrC);
        cudaFree(devPtrD);
        free(matrix_out_cpu);
        free(matrix_out_gpu);
}

int main(){
    float rand_min = -10.0, rand_max = 10.0, rand_num = 0.0;

    float* matrix_in1 = (float*)malloc(sizeof(float) * M * K);
    float* matrix_in2 = (float*)malloc(sizeof(float) * K * N);
    float* matrix_out_cpu = (float*)malloc(sizeof(float) * M * N);
    float* matrix_out_gpu = (float*)malloc(sizeof(float) * M * N);

    for (int i = 0; i< M * K; i++){
        rand_num = (float)rand() / RAND_MAX; // RAND_MAX = 32767
        matrix_in1[i] = rand_min + rand_num * (rand_max - rand_min);
    }
    for (int i = 0; i < K * N; ++i) {
        rand_num = (float)rand()/RAND_MAX;
        matrix_in2[i] = rand_min + rand_num * (rand_max - rand_min);
    }

    clock_t start, stop;
    float a = 1.0, b = 0.0;
    double duration;
    
    // // record cpu execution time
    // start=clock();
    // cpuSgemm(M, N, K, &a, matrix_in1, matrix_in2, &b, matrix_out_cpu);
    // stop=clock();
    // duration=(double)(stop-start)/CLOCKS_PER_SEC;
    // printf("cpu time:%f\n",duration);

    ///////////////////////////////////////////////////////////////////////////////////
    gpuSgemm(M, N, K, &a, matrix_in1, matrix_in2, &b, matrix_out_gpu);
  
    // float EPSILON = 0.1;
    // // check result                                             
    // printf("check\n");
    // for (int i = 0; i < M * N; ++i) {
    //     float error = (matrix_out_cpu[i] - matrix_out_gpu[i]) 
    //         / matrix_out_gpu[i];
    //     if (error < -EPSILON || error > EPSILON)
    //         printf("wrong, %f, %f, %f\n", matrix_out_cpu[i], matrix_out_gpu[i], 
    //             error);
    // }
    // printf("right\n");

    //release memory on host
    free(matrix_in1);
    free(matrix_in2);
    free(matrix_out_cpu);
    free(matrix_out_gpu);

    return 0;
}