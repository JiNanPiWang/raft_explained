/*
 * Copyright (c) 2023-2024, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
/*
 * 2024-3-20
 */
/*
 * 全局内存 (Global Memory): 全局内存是在GPU设备上的内存，可以由所有GPU线程访问。
 * 在代码中，如dataset_ptr, queries_ptr, knn_graph, seed_ptr, visited_hashmap_ptr, 
 * result_indices_ptr, 和 result_distances_ptr等指针指向的是全局内存中的数据。
 * 共享内存 (Shared Memory): 共享内存是在GPU上的快速但大小有限的存储空间，由同一个线程块（block）内的所有线程共享。
 * 在代码中，extern __shared__ uint32_t smem[]; 分配的是共享内存，它在核函数search_kernel中被用作多种数据缓冲区的存储空间。
 * 寄存器 (Registers): 寄存器是每个线程独有的非常快速的存储，用于存储局部变量。
 * 在代码中，如warp_id, lane_id, block_id, num_blocks, iter等都可能被存储在寄存器中。
*/
#pragma once

#include "bitonic.hpp"
#include "compute_distance.hpp"
#include "device_common.hpp"
#include "hashmap.hpp"
#include "search_plan.cuh"
#include "topk_for_cagra/topk_core.cuh"  // TODO replace with raft topk if possible
#include "utils.hpp"

#include <raft/core/device_mdspan.hpp>
#include <raft/core/logger.hpp>
#include <raft/core/resource/cuda_stream.hpp>
#include <raft/core/resource/device_properties.hpp>
#include <raft/core/resources.hpp>
#include <raft/neighbors/sample_filter_types.hpp>
#include <raft/spatial/knn/detail/ann_utils.cuh>
#include <raft/util/cuda_rt_essentials.hpp>
#include <raft/util/cudart_utils.hpp>  // RAFT_CUDA_TRY_NOT_THROW is used TODO(tfeher): consider moving this to cuda_rt_essentials.hpp

#include <algorithm>
#include <cassert>
#include <iostream>
#include <memory>
#include <numeric>
#include <vector>

namespace raft::neighbors::cagra::detail
{
    namespace multi_cta_search
    {

// #define _CLK_BREAKDOWN

        template<class INDEX_T>
        __device__ void pickup_next_parents(INDEX_T *const next_parent_indices,  // [search_width]一个指向存储下一轮父节点索引的数组的指针
                                            const uint32_t search_width,  // 下一轮父节点索引数组的宽度
                                            INDEX_T *const itopk_indices,  // [num_itopk]一个指向存储当前最优k个节点的数组的指针
                                            const size_t num_itopk,  // 当前最优k个节点的数量
                                            uint32_t *const terminate_flag)  // 一个指向终止标志的指针，用于指示搜索是否应该停止
        {
            // 用于检测索引最高位是否被设置的掩码（？）
            constexpr INDEX_T index_msb_1_mask = utils::gen_index_msb_1_mask<INDEX_T>::value;

            // warp_id和lane_id：分别表示当前线程所在的warp ID和在warp中的位置
            const unsigned warp_id = threadIdx.x / 32;
            // 函数只在每个block的第一个warp中执行
            if (warp_id > 0)  
                return; 
            const unsigned lane_id = threadIdx.x % 32;

            // 初始化为最大值
            for (uint32_t i = lane_id; i < search_width; i += 32)
            {
                next_parent_indices[i] = utils::get_max_value<INDEX_T>();
            }

            // 计算max_itopk，确保它是32的倍数，这与warp中的线程数（32）对齐。
            // 它是为了确保在后续的循环中处理的元素数量是32的倍数，这样可以保证所有的线程都能均匀地参与计算。
            uint32_t max_itopk = num_itopk;
            if (max_itopk % 32) 
                max_itopk += 32 - (max_itopk % 32); 

            uint32_t num_new_parents = 0;
            // 第一个warp中的第一个线程（lane_id为0）将处理索引为0、32、64...的元素。
            // 第一个warp中的第二个线程（lane_id为1）将处理索引为1、33、65...的元素。
            for (uint32_t j = lane_id; j < max_itopk; j += 32)
            {
                INDEX_T index;
                int new_parent = 0;
                if (j < num_itopk)
                {
                    // 检查每个索引的最高有效位（MSB）。如果MSB为0，则表示该节点尚未作为父节点使用，并将其标记为新的父节点。
                    index = itopk_indices[j];
                    if ((index & index_msb_1_mask) == 0)
                    {  // check if most significant bit is set
                        new_parent = 1;
                    }
                }

                // 使用__ballot_sync函数，函数在warp内部进行投票，每个线程投票表示是否找到了新的父节点。
                // 这个函数返回一个32位的掩码，每个位对应一个线程，如果线程投票为新的父节点，则相应的位被设置为1。                
                const uint32_t ballot_mask = __ballot_sync(0xffffffff, new_parent);
                if (new_parent)
                {
                    // 如果找到了新的父节点，函数将其索引加入到next_parent_indices
                    // 并将其在itopk_indices中对应的索引的MSB设置为1，表示该节点已被使用。

                    // _popc用于计算一个整数中设置为1的位的数量
                    // 如果lane_id是3，那么((1 << lane_id) - 1)的结果将是0000 0111

                    // 下面这行代码的目的是确定当前线程应该在next_parent_indices数组中的哪个位置写入它找到的新父节点的索引。
                    // 这是通过计算当前线程之前有多少线程已经找到新父节点，并在此基础上添加之前已找到的新父节点的数量来实现的。
                    const auto i = __popc(ballot_mask & ((1 << lane_id) - 1)) + num_new_parents;
                    if (i < search_width)
                    {
                        // 如果找到了新的父节点，函数将其索引加入到next_parent_indices
                        // 并将其在itopk_indices中对应的索引的MSB设置为1，表示该节点已被使用。
                        // 如果在循环的任何时候，找到的新父节点数量达到了搜索宽度search_width，循环就会终止。
                        next_parent_indices[i] = j;
                        itopk_indices[j] |= index_msb_1_mask;  // set most significant bit as used node
                    }
                }
                num_new_parents += __popc(ballot_mask);
                if (num_new_parents >= search_width) 
                    break; 
            }
            // 最后，如果函数在第一个线程中运行并且没有找到任何新的父节点，它将设置终止标志terminate_flag为1。
            if (threadIdx.x == 0 && (num_new_parents == 0))
                *terminate_flag = 1; 
        }

        template<unsigned MAX_ELEMENTS, class INDEX_T>
        __device__ inline void topk_by_bitonic_sort(float *distances,  // [num_elements]
                                                    INDEX_T *indices,  // [num_elements]
                                                    const uint32_t num_elements,
                                                    const uint32_t num_itopk  // num_itopk <= num_elements
        )
        {
            const unsigned warp_id = threadIdx.x / 32;
            if (warp_id > 0) { return; }
            const unsigned lane_id = threadIdx.x % 32;
            constexpr unsigned N = (MAX_ELEMENTS + 31) / 32;
            float key[N];
            INDEX_T val[N];
            for (unsigned i = 0; i < N; i++)
            {
                unsigned j = lane_id + (32 * i);
                if (j < num_elements)
                {
                    key[i] = distances[j];
                    val[i] = indices[j];
                }
                else
                {
                    key[i] = utils::get_max_value<float>();
                    val[i] = utils::get_max_value<INDEX_T>();
                }
            }
            /* Warp Sort */
            bitonic::warp_sort<float, INDEX_T, N>(key, val);
            /* Store itopk sorted results */
            for (unsigned i = 0; i < N; i++)
            {
                unsigned j = (N * lane_id) + i;
                if (j < num_itopk)
                {
                    distances[j] = key[i];
                    indices[j] = val[i];
                }
            }
        }

//
// multiple CTAs per single query
//
        template<unsigned TEAM_SIZE,
                unsigned MAX_ELEMENTS,
                unsigned DATASET_BLOCK_DIM,
                class DATA_T,
                class DISTANCE_T,
                class INDEX_T,
                class LOAD_T,
                class SAMPLE_FILTER_T>
        __launch_bounds__(1024, 1) RAFT_KERNEL search_kernel(
                INDEX_T *const result_indices_ptr,       // [num_queries, num_cta_per_query, itopk_size]
                DISTANCE_T *const result_distances_ptr,  // [num_queries, num_cta_per_query, itopk_size]
                const DATA_T *const dataset_ptr,         // [dataset_size, dataset_dim]
                const size_t dataset_dim,
                const size_t dataset_size,
                const size_t dataset_ld,
                const DATA_T *const queries_ptr,  // [num_queries, dataset_dim]
                const INDEX_T *const knn_graph,   // [dataset_size, graph_degree]
                const uint32_t graph_degree,
                const unsigned num_distilation,
                const uint64_t rand_xor_mask,
                const INDEX_T *seed_ptr,  // [num_queries, num_seeds]
                const uint32_t num_seeds,
                INDEX_T *const visited_hashmap_ptr,  // [num_queries, 1 << hash_bitlen]
                const uint32_t hash_bitlen,
                const uint32_t itopk_size,
                const uint32_t search_width,
                const uint32_t min_iteration,
                const uint32_t max_iteration,
                uint32_t *const num_executed_iterations, /* stats */
                SAMPLE_FILTER_T sample_filter)
        {
            const auto num_queries = gridDim.y;
            const auto query_id = blockIdx.y;
            const auto num_cta_per_query = gridDim.x;
            const auto cta_id = blockIdx.x;  // local CTA ID

#ifdef _CLK_BREAKDOWN
            uint64_t clk_init                 = 0;
            uint64_t clk_compute_1st_distance = 0;
            uint64_t clk_topk                 = 0;
            uint64_t clk_pickup_parents       = 0;
            uint64_t clk_compute_distance     = 0;
            uint64_t clk_start;
#define _CLK_START() clk_start = clock64()
#define _CLK_REC(V)  V += clock64() - clk_start;
#else
#define _CLK_START()
#define _CLK_REC(V)
#endif
            _CLK_START();

            // 声明了一个外部定义的共享内存数组 smem，它是一个无边界大小的数组，
            // 这意味着数组的大小是在运行时确定的，具体大小取决于核函数启动配置时分配的共享内存大小。
            extern __shared__ uint32_t smem[];

            // Layout of result_buffer
            // +----------------+------------------------------+---------+
            // | internal_top_k | neighbors of parent nodes    | padding |
            // | <itopk_size>   | <search_width * graph_degree> | upto 32 |
            // +----------------+------------------------------+---------+
            // |<---          result_buffer_size           --->|
            // 用于存储top-k查询结果的缓冲区和父节点的邻居信息，padding用于确保数据对齐

            uint32_t result_buffer_size = itopk_size + (search_width * graph_degree);
            uint32_t result_buffer_size_32 = result_buffer_size;
            if (result_buffer_size % 32) 
            { 
                result_buffer_size_32 += 32 - (result_buffer_size % 32); 
            }
            assert(result_buffer_size_32 <= MAX_ELEMENTS);

            // ceildiv: Provide a ceiling division operation ie. ceil(a / b)
            const auto query_smem_buffer_length =
                    raft::ceildiv<uint32_t>(dataset_dim, DATASET_BLOCK_DIM) * DATASET_BLOCK_DIM;
            // 构建指向不同数据段的指针
            auto query_buffer = reinterpret_cast<float *>(smem);
            auto result_indices_buffer = reinterpret_cast<INDEX_T *>(query_buffer + query_smem_buffer_length);
            auto result_distances_buffer =
                    reinterpret_cast<DISTANCE_T *>(result_indices_buffer + result_buffer_size_32);
            auto parent_indices_buffer =
                    reinterpret_cast<INDEX_T *>(result_distances_buffer + result_buffer_size_32);
            auto terminate_flag = reinterpret_cast<uint32_t *>(parent_indices_buffer + search_width);

#if 0
            /* debug */
            for (unsigned i = threadIdx.x; i < result_buffer_size_32; i += BLOCK_SIZE) {
                result_indices_buffer[i] = utils::get_max_value<INDEX_T>();
                result_distances_buffer[i] = utils::get_max_value<DISTANCE_T>();
            }
#endif
            const DATA_T *const query_ptr = queries_ptr + (dataset_dim * query_id);
            for (unsigned i = threadIdx.x; i < query_smem_buffer_length; i += blockDim.x)
            {
                unsigned j = device::swizzling(i);
                if (i < dataset_dim)
                {
                    query_buffer[j] = spatial::knn::detail::utils::mapping<float>{}(query_ptr[i]);
                }
                else
                {
                    query_buffer[j] = 0.0;
                }
            }
            if (threadIdx.x == 0) { terminate_flag[0] = 0; }
            INDEX_T *const local_visited_hashmap_ptr =
                    visited_hashmap_ptr + (hashmap::get_size(hash_bitlen) * query_id);
            __syncthreads();
            _CLK_REC(clk_init);

            // compute distance to randomly selecting nodes
            _CLK_START();
            const INDEX_T *const local_seed_ptr = seed_ptr ? seed_ptr + (num_seeds * query_id) : nullptr;
            uint32_t block_id = cta_id + (num_cta_per_query * query_id);
            uint32_t num_blocks = num_cta_per_query * num_queries;
            device::compute_distance_to_random_nodes<TEAM_SIZE, DATASET_BLOCK_DIM, LOAD_T>(
                    result_indices_buffer,
                    result_distances_buffer,
                    query_buffer,
                    dataset_ptr,
                    dataset_dim,
                    dataset_size,
                    dataset_ld,
                    result_buffer_size,
                    num_distilation,
                    rand_xor_mask,
                    local_seed_ptr,
                    num_seeds,
                    local_visited_hashmap_ptr,
                    hash_bitlen,
                    block_id,
                    num_blocks);
            __syncthreads();
            _CLK_REC(clk_compute_1st_distance);

            uint32_t iter = 0;
            while (1)
            {
                // topk with bitonic sort
                _CLK_START();
                topk_by_bitonic_sort<MAX_ELEMENTS, INDEX_T>(result_distances_buffer,
                                                            result_indices_buffer,
                                                            itopk_size + (search_width * graph_degree),
                                                            itopk_size);
                _CLK_REC(clk_topk);

                if (iter + 1 == max_iteration)
                {
                    __syncthreads();
                    break;
                }

                // pick up next parents
                _CLK_START();
                pickup_next_parents<INDEX_T>(
                        parent_indices_buffer, search_width, result_indices_buffer, itopk_size, terminate_flag);
                _CLK_REC(clk_pickup_parents);

                __syncthreads();
                if (*terminate_flag && iter >= min_iteration) { break; }

                // compute the norms between child nodes and query node
                _CLK_START();
                // constexpr unsigned max_n_frags = 16;
                constexpr unsigned max_n_frags = 0;
                device::compute_distance_to_child_nodes<TEAM_SIZE, DATASET_BLOCK_DIM, max_n_frags, LOAD_T>(
                        result_indices_buffer + itopk_size,
                        result_distances_buffer + itopk_size,
                        query_buffer,
                        dataset_ptr,
                        dataset_dim,
                        dataset_ld,
                        knn_graph,
                        graph_degree,
                        local_visited_hashmap_ptr,
                        hash_bitlen,
                        parent_indices_buffer,
                        result_indices_buffer,
                        search_width);
                _CLK_REC(clk_compute_distance);
                __syncthreads();

                // Filtering
                if constexpr (!std::is_same<SAMPLE_FILTER_T,
                        raft::neighbors::filtering::none_cagra_sample_filter>::value)
                {
                    constexpr INDEX_T index_msb_1_mask = utils::gen_index_msb_1_mask<INDEX_T>::value;
                    const INDEX_T invalid_index = utils::get_max_value<INDEX_T>();

                    for (unsigned p = threadIdx.x; p < search_width; p += blockDim.x)
                    {
                        if (parent_indices_buffer[p] != invalid_index)
                        {
                            const auto parent_id =
                                    result_indices_buffer[parent_indices_buffer[p]] & ~index_msb_1_mask;
                            if (!sample_filter(query_id, parent_id))
                            {
                                // If the parent must not be in the resulting top-k list, remove from the parent list
                                result_distances_buffer[parent_indices_buffer[p]] = utils::get_max_value<DISTANCE_T>();
                                result_indices_buffer[parent_indices_buffer[p]] = invalid_index;
                            }
                        }
                    }
                    __syncthreads();
                }

                iter++;
            }

            // Post process for filtering
            if constexpr (!std::is_same<SAMPLE_FILTER_T,
                    raft::neighbors::filtering::none_cagra_sample_filter>::value)
            {
                constexpr INDEX_T index_msb_1_mask = utils::gen_index_msb_1_mask<INDEX_T>::value;
                const INDEX_T invalid_index = utils::get_max_value<INDEX_T>();

                for (unsigned i = threadIdx.x; i < itopk_size + search_width * graph_degree; i += blockDim.x)
                {
                    const auto node_id = result_indices_buffer[i] & ~index_msb_1_mask;
                    if (node_id != (invalid_index & ~index_msb_1_mask) && !sample_filter(query_id, node_id))
                    {
                        // If the parent must not be in the resulting top-k list, remove from the parent list
                        result_distances_buffer[i] = utils::get_max_value<DISTANCE_T>();
                        result_indices_buffer[i] = invalid_index;
                    }
                }

                __syncthreads();
                topk_by_bitonic_sort<MAX_ELEMENTS, INDEX_T>(result_distances_buffer,
                                                            result_indices_buffer,
                                                            itopk_size + (search_width * graph_degree),
                                                            itopk_size);
                __syncthreads();
            }

            for (uint32_t i = threadIdx.x; i < itopk_size; i += blockDim.x)
            {
                uint32_t j = i + (itopk_size * (cta_id + (num_cta_per_query * query_id)));
                if (result_distances_ptr != nullptr) { result_distances_ptr[j] = result_distances_buffer[i]; }
                constexpr INDEX_T index_msb_1_mask = utils::gen_index_msb_1_mask<INDEX_T>::value;

                result_indices_ptr[j] =
                        result_indices_buffer[i] & ~index_msb_1_mask;  // clear most significant bit
            }

            if (threadIdx.x == 0 && cta_id == 0 && num_executed_iterations != nullptr)
            {
                num_executed_iterations[query_id] = iter + 1;
            }

#ifdef _CLK_BREAKDOWN
            if ((threadIdx.x == 0 || threadIdx.x == BLOCK_SIZE - 1) && (blockIdx.x == 0) &&
                ((query_id * 3) % gridDim.y < 3)) {
              RAFT_LOG_DEBUG(
                "query, %d, thread, %d"
                ", init, %d"
                ", 1st_distance, %lu"
                ", topk, %lu"
                ", pickup_parents, %lu"
                ", distance, %lu"
                "\n",
                query_id,
                threadIdx.x,
                clk_init,
                clk_compute_1st_distance,
                clk_topk,
                clk_pickup_parents,
                clk_compute_distance);
            }
#endif
        }

        template<class T>
        RAFT_KERNEL set_value_batch_kernel(T *const dev_ptr,
                                           const std::size_t ld,
                                           const T val,
                                           const std::size_t count,
                                           const std::size_t batch_size)
        {
            const auto tid = threadIdx.x + blockIdx.x * blockDim.x;
            if (tid >= count * batch_size) { return; }
            const auto batch_id = tid / count;
            const auto elem_id = tid % count;
            dev_ptr[elem_id + ld * batch_id] = val;
        }

        template<class T>
        void set_value_batch(T *const dev_ptr,
                             const std::size_t ld,
                             const T val,
                             const std::size_t count,
                             const std::size_t batch_size,
                             cudaStream_t cuda_stream)
        {
            constexpr std::uint32_t block_size = 256;
            const auto grid_size = (count * batch_size + block_size - 1) / block_size;
            set_value_batch_kernel<T>
            <<<grid_size, block_size, 0, cuda_stream>>>(dev_ptr, ld, val, count, batch_size);
        }

        template<unsigned TEAM_SIZE,
                unsigned DATASET_BLOCK_DIM,
                typename DATA_T,
                typename INDEX_T,
                typename DISTANCE_T,
                typename SAMPLE_FILTER_T>
        struct search_kernel_config
        {
            // Search kernel function type. Note that the actual values for the template value
            // parameters do not matter, because they are not part of the function signature. The
            // second to fourth value parameters will be selected by the choose_* functions below.
            using kernel_t = decltype(&search_kernel<TEAM_SIZE,
                    128,
                    DATASET_BLOCK_DIM,
                    DATA_T,
                    DISTANCE_T,
                    INDEX_T,
                    device::LOAD_128BIT_T,
                    SAMPLE_FILTER_T>);

            static auto choose_buffer_size(unsigned result_buffer_size, unsigned block_size) -> kernel_t
            {
                if (result_buffer_size <= 64)
                {
                    return search_kernel<TEAM_SIZE,
                            64,
                            DATASET_BLOCK_DIM,
                            DATA_T,
                            DISTANCE_T,
                            INDEX_T,
                            device::LOAD_128BIT_T,
                            SAMPLE_FILTER_T>;
                }
                else if (result_buffer_size <= 128)
                {
                    return search_kernel<TEAM_SIZE,
                            128,
                            DATASET_BLOCK_DIM,
                            DATA_T,
                            DISTANCE_T,
                            INDEX_T,
                            device::LOAD_128BIT_T,
                            SAMPLE_FILTER_T>;
                }
                else if (result_buffer_size <= 256)
                {
                    return search_kernel<TEAM_SIZE,
                            256,
                            DATASET_BLOCK_DIM,
                            DATA_T,
                            DISTANCE_T,
                            INDEX_T,
                            device::LOAD_128BIT_T,
                            SAMPLE_FILTER_T>;
                }
                THROW("Result buffer size %u larger than max buffer size %u", result_buffer_size, 256);
            }
        };

        template<unsigned TEAM_SIZE,
                unsigned DATASET_BLOCK_DIM,
                typename DATA_T,
                typename INDEX_T,
                typename DISTANCE_T,
                typename SAMPLE_FILTER_T>
        void select_and_run(  // raft::resources const& res,
                raft::device_matrix_view<const DATA_T, int64_t, layout_stride> dataset,
                raft::device_matrix_view<const INDEX_T, int64_t, row_major> graph,
                INDEX_T *const topk_indices_ptr,       // [num_queries, topk]
                DISTANCE_T *const topk_distances_ptr,  // [num_queries, topk]
                const DATA_T *const queries_ptr,       // [num_queries, dataset_dim]
                const uint32_t num_queries,
                const INDEX_T *dev_seed_ptr,              // [num_queries, num_seeds]
                uint32_t *const num_executed_iterations,  // [num_queries,]
                uint32_t topk,
                // multi_cta_search (params struct)
                uint32_t block_size,  //
                uint32_t result_buffer_size,
                uint32_t smem_size,
                int64_t hash_bitlen,
                INDEX_T *hashmap_ptr,
                uint32_t num_cta_per_query,
                uint32_t num_random_samplings,
                uint64_t rand_xor_mask,
                uint32_t num_seeds,
                size_t itopk_size,
                size_t search_width,
                size_t min_iterations,
                size_t max_iterations,
                SAMPLE_FILTER_T sample_filter,
                cudaStream_t stream)
        {
            auto kernel =
                    search_kernel_config<TEAM_SIZE,
                            DATASET_BLOCK_DIM,
                            DATA_T,
                            INDEX_T,
                            DISTANCE_T,
                            SAMPLE_FILTER_T>::choose_buffer_size(result_buffer_size, block_size);

            RAFT_CUDA_TRY(
                    cudaFuncSetAttribute(kernel, cudaFuncAttributeMaxDynamicSharedMemorySize, smem_size));
            // Initialize hash table
            const uint32_t hash_size = hashmap::get_size(hash_bitlen);
            set_value_batch(
                    hashmap_ptr, hash_size, utils::get_max_value<INDEX_T>(), hash_size, num_queries, stream);

            dim3 block_dims(block_size, 1, 1);
            dim3 grid_dims(num_cta_per_query, num_queries, 1);
            RAFT_LOG_DEBUG("Launching kernel with %u threads, (%u, %u) blocks %u smem",
                           block_size,
                           num_cta_per_query,
                           num_queries,
                           smem_size);
            kernel<<<grid_dims, block_dims, smem_size, stream>>>(topk_indices_ptr,
                                                                 topk_distances_ptr,
                                                                 dataset.data_handle(),
                                                                 dataset.extent(1),
                                                                 dataset.extent(0),
                                                                 dataset.stride(0),
                                                                 queries_ptr,
                                                                 graph.data_handle(),
                                                                 graph.extent(1),
                                                                 num_random_samplings,
                                                                 rand_xor_mask,
                                                                 dev_seed_ptr,
                                                                 num_seeds,
                                                                 hashmap_ptr,
                                                                 hash_bitlen,
                                                                 itopk_size,
                                                                 search_width,
                                                                 min_iterations,
                                                                 max_iterations,
                                                                 num_executed_iterations,
                                                                 sample_filter);
        }

    }  // namespace multi_cta_search
}  // namespace raft::neighbors::cagra::detail
