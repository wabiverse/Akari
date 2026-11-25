#ifndef PXR_BASE_TF_SHARED_PTR_RETAIN_RELEASE_HELPER_H
#define PXR_BASE_TF_SHARED_PTR_RETAIN_RELEASE_HELPER_H

#include <pxr/pxr.h>

#include <tbb/concurrent_hash_map.h>

#include <memory>
#include <utility>

PXR_NAMESPACE_OPEN_SCOPE

/// bridges `std::shared_ptr` reference counting to swift's arc for types that can't use the tf retain helper
template<class T> class Tf_SharedPtrRetainReleaseHelper {
 public:
  static T *Register(const std::shared_ptr<T> &ptr)
  {
    T *raw = ptr.get();
    typename _Table::accessor entry;
    _GetTable().insert(entry, raw);
    entry->second.first = ptr;
    entry->second.second += 1;
    return raw;
  }

  static void Retain(T *raw)
  {
    typename _Table::accessor entry;
    if (_GetTable().find(entry, raw)) {
      entry->second.second += 1;
    }
  }

  static void Release(T *raw)
  {
    // destroyed after the entry's lock drops in case its destructor retains or releases something
    std::shared_ptr<T> last;
    {
      typename _Table::accessor entry;
      if (!_GetTable().find(entry, raw) || --entry->second.second != 0) {
        return;
      }

      last = std::move(entry->second.first);
      _GetTable().erase(entry);
    }
  }

 private:
  using _Entry = std::pair<std::shared_ptr<T>, int>;
  using _Table = tbb::concurrent_hash_map<T *, _Entry>;

  static _Table &_GetTable()
  {
    static _Table table;
    return table;
  }
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif  // PXR_BASE_TF_SHARED_PTR_RETAIN_RELEASE_HELPER_H
