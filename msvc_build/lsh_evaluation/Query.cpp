#include "Query.h"
#include "KDTree.h"
#include <tbb/tbb.h>
#undef min
#undef max

namespace popsift {
namespace kdtree {

struct Q2NNAccumulator
{
    unsigned distance[2];
    unsigned index[2];

    Q2NNAccumulator()
    {
        distance[0] = distance[1] = std::numeric_limits<unsigned>::max();
        index[0] = index[1] = -1;
    }

    inline void Update(unsigned d, unsigned i);
    Q2NNAccumulator Combine(const Q2NNAccumulator& other) const;

    void Validate() const
    {
        POPSIFT_KDASSERT(distance[0] < distance[1]);
        POPSIFT_KDASSERT(index[0] != index[1]);
    }
};

inline void Q2NNAccumulator::Update(unsigned d, unsigned i)
{
    if (d < distance[0]) {
        distance[1] = distance[0]; distance[0] = d;
        index[1] = index[0]; index[0] = i;
    }
    else if (d != distance[0] && d < distance[1]) {
        distance[1] = d;
        index[1] = i;
    }
    Validate();
}

Q2NNAccumulator Q2NNAccumulator::Combine(const Q2NNAccumulator& other) const
{
    Q2NNAccumulator r;

    if (distance[0] == other.distance[0]) {
        r.distance[0] = distance[0];
        r.index[0] = index[0];

        if (distance[1] < other.distance[1]) {
            r.distance[1] = distance[1];
            r.index[1] = index[1];
        }
        else {
            r.distance[1] = other.distance[1];
            r.index[1] = other.index[1];
        }
    }
    else if (distance[0] < other.distance[0]) {
        r.distance[0] = distance[0];
        r.index[0] = index[0];

        if (other.distance[0] < distance[1]) {
            r.distance[1] = other.distance[0];
            r.index[1] = other.index[0];
        }
        else {
            r.distance[1] = distance[1];
            r.index[1] = index[1];
        }
    }
    else {
        r.distance[0] = other.distance[0];
        r.index[0] = other.index[0];

        if (distance[0] < other.distance[1]) {
            r.distance[1] = distance[0];
            r.index[1] = index[0];
        }
        else {
            r.distance[1] = other.distance[1];
            r.index[1] = other.index[1];
        }
    }

    r.Validate();
    return r;
}

class Q2NNpq    // std::priority_queue doesn't support preallocation
{
public:
    struct Entry {
        unsigned short distance;    // max L1 distance is 255*128 = 32640
        unsigned short tree;
        unsigned node;
        friend bool operator<(const Entry& e1, const Entry& e2) {
            return e1.distance > e2.distance;   // Reverse heap ordering; smallest on top
        }
    };

    Q2NNpq()
    {
        _pq.reserve(4096);  // Should be more than #trees * #levels to avoid allocations on Push/Pop
    }

    template<typename Mutex>
    void Push(const Entry& e, Mutex& mtx)
    {
        Mutex::scoped_lock lk(mtx);
        Push(e);
    }

    template<typename Mutex>
    bool Pop(Entry& e, Mutex& mtx)
    {
        Mutex::scoped_lock lk(mtx);
        return Pop(e);
    }

private:
    void Push(const Entry& e)
    {
        _pq.push_back(e);
        std::push_heap(_pq.begin(), _pq.end());
    }

    bool Pop(Entry& e)
    {
        if (_pq.empty())
            return false;
        e = _pq.front();
        std::pop_heap(_pq.begin(), _pq.end());
        _pq.pop_back();
        return true;
    }

    std::vector<Entry> _pq;
};

class Candidate2NNQuery
{
    const std::vector<KDTreePtr>& _trees;
    const U8Descriptor& _descriptor;
    const size_t _max_descriptors;

    Q2NNpq _pq;
    tbb::null_mutex _pqmtx;
    std::vector<KDTree::Leaf> _leafs;
    size_t _found_descriptors;

    bool ProcessPQ();

public:
    Candidate2NNQuery(const std::vector<KDTreePtr>& trees, const U8Descriptor& descriptor, size_t max_descriptors);
    std::vector<KDTree::Leaf> operator()();
};

Candidate2NNQuery::Candidate2NNQuery(const std::vector<KDTreePtr>& trees, const U8Descriptor& descriptor, size_t max_descriptors) :
    _trees(trees), _descriptor(descriptor), _max_descriptors(max_descriptors), _found_descriptors(0)
{
    _leafs.reserve(_max_descriptors / 32);
}

std::vector<KDTree::Leaf> Candidate2NNQuery::operator()()
{
    for (unsigned short i = 0; i < _trees.size(); ++i) {
        unsigned short d = L1Distance(_descriptor, _trees[i]->BB(0));
        _pq.Push(Q2NNpq::Entry{ d, i, 0 }, _pqmtx);
    }

    while (_found_descriptors < _max_descriptors && ProcessPQ())
        ;

    return std::move(_leafs);
}

bool Candidate2NNQuery::ProcessPQ()
{
    Q2NNpq::Entry pqe;
    if (!_pq.Pop(pqe, _pqmtx))
        return false;
    
    const KDTree& tree = *_trees[pqe.tree];
    
    if (tree.IsLeaf(pqe.node)) {
        auto list = tree.List(pqe.node);
        _leafs.push_back(list);
        _found_descriptors += list.second - list.first;
    }
    else {
        unsigned short l = tree.Left(pqe.node), dl = L1Distance(_descriptor, tree.BB(l));
        unsigned short r = tree.Right(pqe.node), dr = L1Distance(_descriptor, tree.BB(r));
        _pq.Push(Q2NNpq::Entry{ dl, pqe.tree, l }, _pqmtx);
        _pq.Push(Q2NNpq::Entry{ dr, pqe.tree, r }, _pqmtx);
    }

    return true;
}

std::vector<KDTree::Leaf> Query2NNLeafs(const std::vector<KDTreePtr>& trees, const U8Descriptor& descriptor, size_t max_descriptors)
{
    Candidate2NNQuery q(trees, descriptor, max_descriptors);
    return q();
}

std::pair<unsigned, unsigned> Query2NN(const std::vector<KDTreePtr>& trees, const U8Descriptor& descriptor, size_t max_descriptors)
{
    const U8Descriptor* descriptors = trees.front()->Descriptors();
    auto leafs = Query2NNLeafs(trees, descriptor, max_descriptors);
    Q2NNAccumulator acc;

    for (auto leaf : leafs) {
        for (; leaf.first != leaf.second; ++leaf.first) {
            unsigned d = L1Distance(descriptor, descriptors[*leaf.first]);
            acc.Update(d, *leaf.first);
        }
    }

    return std::make_pair(acc.index[0], acc.index[1]);
}

/////////////////////////////////////////////////////////////////////////////

TreeQuery::TreeQuery(const U8Descriptor * qDescriptors, size_t dcount, 
                    unsigned treeIndex, Query* query)
    :_qDescriptors(qDescriptors),
    _dcount(dcount),
    _initialTreeIndex(treeIndex),
    _query(query)
{
}

void TreeQuery::FindCandidates()
{
    for (int i = 0; i < _dcount; i++) {
        const U8Descriptor& desc = _qDescriptors[i];

        //initial traverse from root-node
        traverse(desc, 0, _initialTreeIndex);

        //followup-traversal based on priority queue
        while (_candidates.size() < _maxCandidates && _query->priority_queue.size() > 0) {
            
            int nextIndex = -1;
            unsigned nextTreeIndex;
            {
                std::lock_guard<std::mutex>(_query->pq_mutex);
                if (_query->priority_queue.size() > 0) {
                    nextIndex = _query->priority_queue.top().nodeIndex;
                    nextTreeIndex = _query->priority_queue.top().treeIndex;
                    _query->priority_queue.pop();
                }
            }
            if (nextIndex >= 0)
                traverse(desc, nextIndex, nextTreeIndex);
        }

        //Moved the priority-queue traversal from leaf-node block 
        //in TreeQuery::traverse to avoid huge stacks
    }
}

void TreeQuery::traverse(const U8Descriptor & q, unsigned nodeIndex, unsigned treeIndex)
{
    const KDTree& tree = _query->Tree(treeIndex);

    if (tree.IsLeaf(nodeIndex)) {
        auto candidates = _tree->List(nodeIndex);
        _candidates.insert(_candidates.end(), candidates.first, candidates.second);
        //todo: can potentially calc dist between q and tree-desc here.
    }
    else {
        if (tree.Val(nodeIndex) < q.ufeatures[tree.Dim(nodeIndex)]) {
            const BoundingBox& rightBB = _tree->BB(_tree->Right(nodeIndex));
            unsigned right_dist = BBDistance(rightBB, q);
            {
                std::lock_guard<std::mutex>(_query->pq_mutex);
                _query->priority_queue.push(Query::PC{ treeIndex, _tree->Right(nodeIndex), right_dist });
            }
            traverse(q, _tree->Left(nodeIndex), treeIndex);
        }
        else {
            const BoundingBox& leftBB = _tree->BB(_tree->Left(nodeIndex));
            unsigned left_dist = BBDistance(leftBB, q);
            
            {
                std::lock_guard<std::mutex>(_query->pq_mutex);
                _query->priority_queue.push(Query::PC{ treeIndex, _tree->Right(nodeIndex), left_dist });
            }
            traverse(q, _tree->Right(nodeIndex), treeIndex);
        }
    }
}

unsigned TreeQuery::BBDistance(const BoundingBox& bb, const U8Descriptor & q)
{
    unsigned sum = 0;
    for (int i = 0; i < 128; i++) {
        if (q.ufeatures[i] < bb.min.ufeatures[i]) {
            sum += bb.min.ufeatures[i] - q.ufeatures[i];
        }
        else if (q.ufeatures[i] > bb.max.ufeatures[i]) {
            sum += q.ufeatures[i] - bb.max.ufeatures[i];
        }
    }
    return sum;
}

Query::Query(const U8Descriptor * qDescriptors, size_t dcount,
    std::vector<std::unique_ptr<KDTree>> trees, unsigned num_threads)
{
    for (int i = 0; i < trees.size(); i++) {
        TreeQuery q(qDescriptors, dcount, i, this);

    }
}


}
}
