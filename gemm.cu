#include <assert.h>
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <iostream>
#include <stdlib.h>
#include <unistd.h>

#ifdef SCOREP
#include <SCOREP_User.h>
#endif

#include "fp16_conversion.h"

using namespace std;

// #define FP16MM

const char *cublasGetErrorString(cublasStatus_t status)
{
    switch (status)
    {
        case CUBLAS_STATUS_SUCCESS:
            return "CUBLAS_STATUS_SUCCESS";
        case CUBLAS_STATUS_NOT_INITIALIZED:
            return "CUBLAS_STATUS_NOT_INITIALIZED";
        case CUBLAS_STATUS_ALLOC_FAILED:
            return "CUBLAS_STATUS_ALLOC_FAILED";
        case CUBLAS_STATUS_INVALID_VALUE:
            return "CUBLAS_STATUS_INVALID_VALUE";
        case CUBLAS_STATUS_ARCH_MISMATCH:
            return "CUBLAS_STATUS_ARCH_MISMATCH";
        case CUBLAS_STATUS_MAPPING_ERROR:
            return "CUBLAS_STATUS_MAPPING_ERROR";
        case CUBLAS_STATUS_EXECUTION_FAILED:
            return "CUBLAS_STATUS_EXECUTION_FAILED";
        case CUBLAS_STATUS_INTERNAL_ERROR:
            return "CUBLAS_STATUS_INTERNAL_ERROR";
    }
    return "unknown error";
}

// Convenience function for checking CUDA runtime API results
// can be wrapped around any runtime API call. No-op in release builds.
inline cudaError_t checkCuda(cudaError_t result)
{
    if (result != cudaSuccess)
    {
        fprintf(stderr, "CUDA Runtime Error: %s\n", cudaGetErrorString(result));
        assert(result == cudaSuccess);
    }
    return result;
}

inline cublasStatus_t checkCublas(cublasStatus_t result)
{
    if (result != CUBLAS_STATUS_SUCCESS)
    {
        fprintf(stderr, "CUDA Runtime Error: %s\n", cublasGetErrorString(result));
        assert(result == CUBLAS_STATUS_SUCCESS);
    }
    return result;
}

// Fill the array A(nr_rows_A, nr_cols_A) with random numbers on CPU
void CPU_fill_rand(float *A, int nr_rows_A, int nr_cols_A)
{
    int a = 1;

    for (int i = 0; i < nr_rows_A * nr_cols_A; i++)
    {
        A[i] = (float) rand() / (float) (RAND_MAX / a);
    }
}

void mat_mul(int m_k_n_size, int repeats, int verbose = 0, int device = 0)
{
    if (device == 0 && verbose)
        cout << "running with"
             << " m_k_n_size: " << m_k_n_size
             << " repeats: " << repeats;
#ifndef FP16MM
    cout << "\ncublasSgemm:\n";
#else
    cout << "\ncublasHgemm :\n";
#endif
    cout << endl;

    cublasStatus_t stat;
    cublasHandle_t handle;

    cudaSetDevice(device);

    checkCublas(cublasCreate(&handle));

    // Allocate 3 arrays on CPU

    float *h_A = (float *) malloc(m_k_n_size * m_k_n_size * sizeof(float));
    float *h_B = (float *) malloc(m_k_n_size * m_k_n_size * sizeof(float));
    float *h_C = (float *) malloc(m_k_n_size * m_k_n_size * sizeof(float));

    CPU_fill_rand(h_A, m_k_n_size, m_k_n_size);
    CPU_fill_rand(h_B, m_k_n_size, m_k_n_size);
    CPU_fill_rand(h_C, m_k_n_size, m_k_n_size);

#ifndef FP16MM
    // Allocate 3 arrays on GPU
    float *d_A, *d_B, *d_C;
    checkCuda(cudaMallocManaged(&d_A, m_k_n_size * m_k_n_size * sizeof(float)));
    checkCuda(cudaMallocManaged(&d_B, m_k_n_size * m_k_n_size * sizeof(float)));
    checkCuda(cudaMallocManaged(&d_C, m_k_n_size * m_k_n_size * sizeof(float)));

    checkCuda(cudaMemcpy(d_A, h_A, m_k_n_size * m_k_n_size * sizeof(float), cudaMemcpyHostToDevice));
    checkCuda(cudaMemcpy(d_B, h_B, m_k_n_size * m_k_n_size * sizeof(float), cudaMemcpyHostToDevice));
    checkCuda(cudaMemcpy(d_C, h_C, m_k_n_size * m_k_n_size * sizeof(float), cudaMemcpyHostToDevice));

    int lda, ldb, ldc, m, n, k;
    const float alf = 1.0f;
    const float bet = 0.0f;
    const float *alpha = &alf;
    const float *beta = &bet;

#else

    __half *d_A, *d_B, *d_C;
    checkCuda(cudaMallocManaged(&d_A, m_k_n * m_k_n * sizeof(__half)));
    checkCuda(cudaMallocManaged(&d_B, m_k_n * m_k_n * sizeof(__half)));
    checkCuda(cudaMallocManaged(&d_C, m_k_n * m_k_n * sizeof(__half)));

    for (int i = 0; i < m_k_n * m_k_n; i++)
    {
        d_A[i] = approx_float_to_half(h_A[i]);
        d_B[i] = approx_float_to_half(h_B[i]);
        d_C[i] = approx_float_to_half(h_C[i]);
    }

    int lda, ldb, ldc, m, n, k;
    const __half alf = approx_float_to_half(1.0);
    const __half bet = approx_float_to_half(0.0);
    const __half *alpha = &alf;
    const __half *beta = &bet;

#endif

    cudaEvent_t start, stop;
    cudaEventCreate(&start);
    cudaEventCreate(&stop);

#ifdef SCOREP
    SCOREP_USER_METRIC_INIT(scorep_metrics_flops, "GPU FLOPS", "FLOPS",
                            SCOREP_USER_METRIC_TYPE_DOUBLE,
                            SCOREP_USER_METRIC_CONTEXT_GLOBAL)
#endif
    double flops;
    for (int rep = 0; rep < repeats; rep++)
    {
        cudaEventRecord(start, 0);
        m = n = k = m_k_n_size;
        lda = m;
        ldb = k;
        ldc = m;
#ifndef FP16MM
        stat = cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, alpha, d_A, lda, d_B, ldb, beta, d_C, ldc);
#else
        stat = cublasHgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, m, n, k, alpha, d_A, lda, d_B, ldb, beta, d_C, ldc);
#endif
        cudaEventRecord(stop, 0);
        cudaEventSynchronize(stop);
        if (stat != CUBLAS_STATUS_SUCCESS)
        {
            cerr << "cublasSgemmBatched failed" << endl;
            exit(1);
        }
        assert(!cudaGetLastError());

        float elapsed;
        cudaEventElapsedTime(&elapsed, start, stop);

        elapsed /= 1000.0f;
        flops = m_k_n_size * m_k_n_size * m_k_n_size / elapsed;

#ifdef SCOREP
        SCOREP_USER_METRIC_DOUBLE(scorep_metrics_flops,flops)
#endif
        if (verbose > 1)
            cout << "device: " << device << " took: " << elapsed << " FLOPS: " << flops << endl;
    }

    //Free GPU memory
    cudaFree(d_A);
    cudaFree(d_B);
    cudaFree(d_C);

    // Free CPU memory
    free(h_A);
    free(h_B);
    free(h_C);
}