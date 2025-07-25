/**
 * Copyright 2020-2025, XGBoost Contributors
 */
#ifndef XGBOOST_COMMON_QUANTILE_CUH_
#define XGBOOST_COMMON_QUANTILE_CUH_

#include <thrust/logical.h>  // for any_of

#include "categorical.h"
#include "common.h"          // for HumanMemUnit
#include "cuda_context.cuh"  // for CUDAContext
#include "cuda_rt_utils.h"   // for SetDevice
#include "device_helpers.cuh"
#include "error_msg.h"  // for InvalidMaxBin
#include "quantile.h"
#include "timer.h"
#include "xgboost/data.h"
#include "xgboost/span.h"

namespace xgboost::common {
class HistogramCuts;
using WQSketch = WQuantileSketch<bst_float, bst_float>;
using SketchEntry = WQSketch::Entry;

namespace detail {
struct SketchUnique {
  XGBOOST_DEVICE bool operator()(SketchEntry const& a, SketchEntry const& b) const {
    return a.value - b.value == 0;
  }
};
}  // namespace detail

/*!
 * \brief A container that holds the device sketches.  Sketching is performed per-column,
 *        but fused into single operation for performance.
 */
class SketchContainer {
 public:
  static constexpr float kFactor = WQSketch::kFactor;
  using OffsetT = bst_idx_t;
  static_assert(sizeof(OffsetT) == sizeof(size_t), "Wrong type for sketch element offset.");

 private:
  Monitor timer_;
  HostDeviceVector<FeatureType> feature_types_;
  bst_idx_t num_rows_;
  bst_feature_t num_columns_;
  int32_t num_bins_;

  // Double buffer as neither prune nor merge can be performed inplace.
  dh::device_vector<SketchEntry> entries_a_;
  dh::device_vector<SketchEntry> entries_b_;
  bool current_buffer_ {true};
  // The container is just a CSC matrix.
  HostDeviceVector<OffsetT> columns_ptr_;
  HostDeviceVector<OffsetT> columns_ptr_b_;

  bool has_categorical_{false};

  dh::device_vector<SketchEntry>& Current() {
    if (current_buffer_) {
      return entries_a_;
    } else {
      return entries_b_;
    }
  }
  dh::device_vector<SketchEntry>& Other() {
    if (!current_buffer_) {
      return entries_a_;
    } else {
      return entries_b_;
    }
  }
  dh::device_vector<SketchEntry> const& Current() const {
    return const_cast<SketchContainer*>(this)->Current();
  }
  dh::device_vector<SketchEntry> const& Other() const {
    return const_cast<SketchContainer*>(this)->Other();
  }
  void Alternate() {
    current_buffer_ = !current_buffer_;
  }

  // Get the span of one column.
  Span<SketchEntry> Column(bst_feature_t i) {
    auto data = dh::ToSpan(this->Current());
    auto h_ptr = columns_ptr_.ConstHostSpan();
    auto c = data.subspan(h_ptr[i], h_ptr[i+1] - h_ptr[i]);
    return c;
  }

 public:
  /* \breif GPU quantile structure, with sketch data for each columns.
   *
   * \param max_bin     Maximum number of bins per columns
   * \param num_columns Total number of columns in dataset.
   * \param num_rows    Total number of rows in known dataset (typically the rows in current worker).
   * \param device      GPU ID.
   */
  SketchContainer(HostDeviceVector<FeatureType> const& feature_types, bst_bin_t max_bin,
                  bst_feature_t num_columns, bst_idx_t num_rows, DeviceOrd device)
      : num_rows_{num_rows}, num_columns_{num_columns}, num_bins_{max_bin} {
    CHECK(device.IsCUDA());
    // Initialize Sketches for this dmatrix
    this->columns_ptr_.SetDevice(device);
    this->columns_ptr_.Resize(num_columns + 1, 0);
    this->columns_ptr_b_.SetDevice(device);
    this->columns_ptr_b_.Resize(num_columns + 1, 0);

    this->feature_types_.Resize(feature_types.Size());
    this->feature_types_.Copy(feature_types);
    // Pull to device.
    this->feature_types_.SetDevice(device);
    this->feature_types_.ConstDeviceSpan();
    this->feature_types_.ConstHostSpan();

    auto d_feature_types = feature_types_.ConstDeviceSpan();
    has_categorical_ =
        !d_feature_types.empty() &&
        thrust::any_of(dh::tbegin(d_feature_types), dh::tend(d_feature_types), common::IsCatOp{});
    CHECK_GE(max_bin, 2) << error::InvalidMaxBin();

    timer_.Init(__func__);
  }
  /**
   * @brief Calculate the memory cost of the container.
   */
  [[nodiscard]] std::size_t MemCapacityBytes() const {
    auto constexpr kE = sizeof(typename decltype(this->entries_a_)::value_type);
    auto n_bytes = (this->entries_a_.capacity() + this->entries_b_.capacity()) * kE;
    n_bytes += (this->columns_ptr_.Size() + this->columns_ptr_b_.Size()) * sizeof(OffsetT);
    n_bytes += this->feature_types_.Size() * sizeof(FeatureType);

    return n_bytes;
  }
  [[nodiscard]] std::size_t MemCostBytes() const {
    auto constexpr kE = sizeof(typename decltype(this->entries_a_)::value_type);
    auto n_bytes = (this->entries_a_.size() + this->entries_b_.size()) * kE;
    n_bytes += (this->columns_ptr_.Size() + this->columns_ptr_b_.Size()) * sizeof(OffsetT);
    n_bytes += this->feature_types_.Size() * sizeof(FeatureType);

    return n_bytes;
  }
  /* \brief Whether the predictor matrix contains categorical features. */
  bool HasCategorical() const { return has_categorical_; }
  /* \brief Accumulate weights of duplicated entries in input. */
  size_t ScanInput(Context const* ctx, Span<SketchEntry> entries, Span<OffsetT> d_columns_ptr_in);
  /* Fix rounding error and re-establish invariance.  The error is mostly generated by the
   * addition inside `RMinNext` and subtraction in `RMaxPrev`. */
  void FixError();

  /* \brief Push sorted entries.
   *
   * \param entries Sorted entries.
   * \param columns_ptr CSC pointer for entries.
   * \param cuts_ptr CSC pointer for cuts.
   * \param total_cuts Total number of cuts, equal to the back of cuts_ptr.
   * \param weights (optional) data weights.
   */
  void Push(Context const* ctx, Span<Entry const> entries, Span<size_t> columns_ptr,
            common::Span<OffsetT> cuts_ptr, size_t total_cuts, Span<float> weights = {});
  /**
   * @brief Prune the quantile structure.
   *
   * @param to The maximum size of pruned quantile.  If the size of quantile structure is
   *           already less than `to`, then no operation is performed.
   */
  void Prune(Context const* ctx, size_t to);
  /**
   * @brief Merge another set of sketch.
   *
   * @param that_columns_ptr Column pointer of the quantile summary being merged.
   * @param that Columns of the other quantile summary.
   */
  void Merge(Context const* ctx, Span<OffsetT const> that_columns_ptr,
             Span<SketchEntry const> that);
  /**
   * @brief Shrink the internal data structure to reduce memory usage. Can be used after
   *        prune.
   */
  void ShrinkToFit() {
    this->Current().shrink_to_fit();
    this->Other().clear();
    this->Other().shrink_to_fit();
    LOG(DEBUG) << "Quantile memory cost:" << common::HumanMemUnit(this->MemCapacityBytes());
  }

  /* \brief Merge quantiles from other GPU workers. */
  void AllReduce(Context const* ctx, bool is_column_split);
  /* \brief Create the final histogram cut values. */
  void MakeCuts(Context const* ctx, HistogramCuts* cuts, bool is_column_split);

  Span<SketchEntry const> Data() const {
    return {this->Current().data().get(), this->Current().size()};
  }
  HostDeviceVector<FeatureType> const& FeatureTypes() const { return feature_types_; }

  Span<OffsetT const> ColumnsPtr() const { return this->columns_ptr_.ConstDeviceSpan(); }

  SketchContainer(SketchContainer&&) = default;
  SketchContainer& operator=(SketchContainer&&) = default;

  SketchContainer(const SketchContainer&) = delete;
  SketchContainer& operator=(const SketchContainer&) = delete;

  /* \brief Removes all the duplicated elements in quantile structure. */
  template <typename KeyComp = thrust::equal_to<size_t>>
  size_t Unique(Context const* ctx, KeyComp key_comp = thrust::equal_to<size_t>{}) {
    timer_.Start(__func__);
    curt::SetDevice(ctx->Ordinal());
    this->columns_ptr_.SetDevice(ctx->Device());
    Span<OffsetT> d_column_scan = this->columns_ptr_.DeviceSpan();
    CHECK_EQ(d_column_scan.size(), num_columns_ + 1);
    Span<SketchEntry> entries = dh::ToSpan(this->Current());
    HostDeviceVector<OffsetT> scan_out(d_column_scan.size());
    scan_out.SetDevice(ctx->Device());
    auto d_scan_out = scan_out.DeviceSpan();

    d_column_scan = this->columns_ptr_.DeviceSpan();
    size_t n_uniques = dh::SegmentedUnique(
        ctx->CUDACtx()->CTP(), d_column_scan.data(), d_column_scan.data() + d_column_scan.size(),
        entries.data(), entries.data() + entries.size(), scan_out.DevicePointer(), entries.data(),
        detail::SketchUnique{}, key_comp);
    this->columns_ptr_.Copy(scan_out);
    CHECK(!this->columns_ptr_.HostCanRead());

    this->Current().resize(n_uniques);
    timer_.Stop(__func__);
    return n_uniques;
  }
};
}  // namespace xgboost::common

#endif  // XGBOOST_COMMON_QUANTILE_CUH_
