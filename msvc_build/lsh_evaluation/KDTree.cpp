#include "KDTree.h"
#include <assert.h>
#include <limits>
#include <random>

namespace popsift {
namespace kdtree {

static void Validate(const KDTree& kdt, unsigned n, size_t& sum)
{
    POPSIFT_KDASSERT(n < kdt.NodeCount());

    {
        const BoundingBox& bb = kdt.BB(n);
        for (int i = 0; i < 128; ++i)
            POPSIFT_KDASSERT(bb.min.ufeatures[i] <= bb.max.ufeatures[i]);
    }

    if (kdt.IsLeaf(n)) {
        for (auto range = kdt.List(n); range.first != range.second; ++range.first) {
            POPSIFT_KDASSERT(*range.first < kdt.DescriptorCount());
            sum += *range.first;
        }
    }
    else {
        POPSIFT_KDASSERT(kdt.Dim(n) < 128);
        Validate(kdt, kdt.Left(n), sum);
        Validate(kdt, kdt.Right(n), sum);
    }
}

KDTreePtr Build(const U8Descriptor* descriptors, size_t dcount, const SplitDimensions& sdim, unsigned leaf_size)
{
    KDTreePtr ret(new KDTree(descriptors, dcount));
    ret->Build(sdim, leaf_size);

    // Always validate, it's cheap.
    {
        size_t sum = 0;
        Validate(*ret, 0, sum);
        // KDT limits count to 2^31, so multiplication won't overflow here.
        POPSIFT_KDASSERT(sum == (size_t(dcount) - 1) * size_t(dcount) / 2);
    }
    
    return ret;
}

std::vector<KDTreePtr> Build(const U8Descriptor* descriptors, size_t descriptor_count, size_t tree_count, unsigned leaf_size)
{
    std::vector<KDTreePtr> ret;
    ret.reserve(tree_count);

    auto sdim = GetSplitDimensions(descriptors, descriptor_count);
    for (size_t i = 0; i < tree_count; ++i)
        ret.push_back(Build(descriptors, descriptor_count, sdim, leaf_size));
    return ret;
}

/////////////////////////////////////////////////////////////////////////////

KDTree::KDTree(const U8Descriptor* descriptors, size_t dcount) :
    _split_dim_gen(0, SPLIT_DIMENSION_COUNT-1),
    _descriptors(descriptors),
    _dcount(static_cast<unsigned>(dcount)),
    _list(dcount)
{
    POPSIFT_KDASSERT(dcount < std::numeric_limits<unsigned>::max() / 2);
    for (unsigned i = 0; i < _dcount; ++i)
        _list[i] = i;
}

// XXX: TODO: Partition() has a static random_engine.  We should explicitly pass it to build.
void KDTree::Build(const SplitDimensions& sdim, unsigned leaf_size)
{
    _leaf_size = leaf_size + 16;    // Don't make too small leafs
    _split_dimensions = sdim;
    _nodes.reserve(2 * _dcount / leaf_size);
    _bb.reserve(2 * _dcount / leaf_size);

    // Generate root node as a leaf containing all points.
    _nodes.emplace_back();
    _bb.emplace_back();
    _nodes.back().leaf = 1;
    
    Build(0, 0, _dcount);
    POPSIFT_KDASSERT(_nodes.size() == _bb.size());
}

// On entry, [lelem, relem) is the element range; node must be a leaf. On exit, node is potentially
// converted to internal node, and dim,val are filled in as well as pointers to children. 
// BB will also be computed.
void KDTree::Build(unsigned node_index, unsigned lelem, unsigned relem)
{
    POPSIFT_KDASSERT(_nodes.size() == _bb.size());
    unsigned melem;

    {
        Node& node = _nodes[node_index];

        POPSIFT_KDASSERT(node.leaf);
        POPSIFT_KDASSERT(lelem < relem);

        if (relem - lelem <= _leaf_size) {
            auto list = List(lelem, relem);
            node.index = lelem;
            node.end = relem;
            _bb[node_index] = GetBoundingBox(_descriptors, list.first, list.second - list.first);
            return;
        }
        
        // NB! Partition returns index from [0,n) where 0 maps to left, n maps to right.
        melem = Partition(node, lelem, relem) + lelem;
    }

    // Left child to split.
    const unsigned lc = static_cast<unsigned>(_nodes.size());
    _nodes.emplace_back();
    _bb.emplace_back();
    _nodes.back().leaf = 1;
    Build(lc, lelem, melem);

    // Right child to split.
    const unsigned rc = static_cast<unsigned>(_nodes.size());
    _nodes.emplace_back();
    _bb.emplace_back();
    _nodes.back().leaf = 1;
    Build(rc, melem, relem);

    POPSIFT_KDASSERT(lc == node_index + 1);
    _nodes[node_index].index = rc;
    _nodes[node_index].leaf = 0;
    _bb[node_index] = Union(_bb[lc], _bb[rc]);
}

// Returns _list.size() if the partitioning fails (i.e. all elements have constant value along the dimension)
// Otherwise returns the partition index and fills in partitioning data in node, marking it internal.
unsigned KDTree::Partition(Node& node, unsigned lelem, unsigned relem)
{
    static std::mt19937_64 rng_engine;  // XXX! NOT MT-SAFE!

    POPSIFT_KDASSERT(node.leaf);

    unsigned split_dim = _split_dimensions[_split_dim_gen(rng_engine)];
    const auto proj = [&split_dim, this](unsigned di) { return _descriptors[di].ufeatures[split_dim]; };
    const auto list = List(lelem, relem);

    // Try partitioning several times.
    for (int retry_count = 0; retry_count < 16; ++retry_count) {
        const auto mm = std::minmax_element(list.first, list.second, [&](unsigned a, unsigned b) { return proj(a) < proj(b); });
        if (proj(*mm.second) - proj(*mm.first) <= 1) {
        retry:
            std::uniform_int_distribution<int> dd(0, 127);
            split_dim = dd(rng_engine);
            continue;
        }

        std::uniform_int_distribution<unsigned> vdist(proj(*mm.first), proj(*mm.second));
        const unsigned split_val = vdist(rng_engine);

        const unsigned* mit = std::partition(list.first, list.second, [&, this](unsigned di) { return proj(di) < split_val; });
        if (mit == list.first || mit == list.second)
            goto retry;

        node.dim() = split_dim;
        node.val() = split_val;
        return static_cast<unsigned>(mit - list.first);
    }
    throw std::runtime_error("KDTree: partitioning failed.");
}

}   // kdtree
}   // popsift
