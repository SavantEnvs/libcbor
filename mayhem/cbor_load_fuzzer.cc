#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <unordered_map>

#include "cbor.h"

static size_t allocated_mem = 0;
static std::unordered_map<void*, size_t> allocated_len_map;
static constexpr size_t kMemoryLimit = 1 << 30;

// Allocation-failure injection: the k-th allocation after arm_failure(k) returns NULL (k >= 1).
static long fail_countdown = -1;

static void arm_failure(int k) { fail_countdown = k > 0 ? k : -1; }

static bool inject_failure() {
    if (fail_countdown < 0) {
        return false;
    }
    if (--fail_countdown == 0) {
        fail_countdown = -1;
        return true;
    }
    return false;
}

void *limited_malloc(size_t size) {
    if (inject_failure()) {
        return nullptr;
    }
    if (size + allocated_mem > kMemoryLimit) {
        return nullptr;
    }
    if (size == 0) {
        return nullptr;
    }
    void* m = malloc(size);
    if (m != nullptr) {
        allocated_mem += size;
        allocated_len_map[m] = size;
    }
    return m;
}

void limited_free(void *ptr) {
    if (ptr != NULL && allocated_len_map.find(ptr) == allocated_len_map.end()) {
        abort();
    }
    free(ptr);
    if (ptr != NULL) {
        allocated_mem -= allocated_len_map[ptr];
        allocated_len_map.erase(ptr);
    }
}

void *limited_realloc(void *ptr, size_t size) {
    if (inject_failure()) {
        return nullptr;
    }
    if (ptr != NULL && allocated_len_map.find(ptr) == allocated_len_map.end()) {
        abort();
    }
    if (ptr == NULL) {
        return limited_malloc(size);
    }
    long delta = (long) size - allocated_len_map[ptr];
    if (delta + allocated_mem > kMemoryLimit) {
        return nullptr;
    }
    void* new_ptr = realloc(ptr, size);
    if (size > 0 && new_ptr == nullptr) {
        return nullptr;
    }
    allocated_mem += delta;
    allocated_len_map.erase(ptr);
    if (size > 0) {
        allocated_len_map[new_ptr] = size;
    }
    return new_ptr;
}

struct State {
    FILE* fout;

    // §6.2 item 13: harness writes must use a relative path or /tmp, never another absolute path.
    State() : fout(fopen("/tmp/cbor_load_fuzzer.out", "w")) {
        cbor_set_allocs(limited_malloc, limited_realloc, limited_free);
    }
};

static State kState;

// Input: [k_copy][k_copy_definite][CBOR bytes]. k_* selects which allocation inside that copy call
// fails (0 = none), so the allocation-failure paths of cbor_copy / cbor_copy_definite are reachable.
extern "C" int LLVMFuzzerTestOneInput(const uint8_t *Data, size_t Size) {
    if (Size < 2) {
        return -1;
    }
    const int k_copy = Data[0];
    const int k_copy_definite = Data[1];
    Data += 2;
    Size -= 2;

    cbor_load_result result;
    cbor_item_t *item = cbor_load(Data, Size, &result);
    if (result.error.code == CBOR_ERR_NONE) {
        cbor_describe(item, kState.fout);
        unsigned char *buffer;
        size_t buffer_size;
        cbor_serialize_alloc(item, &buffer, &buffer_size);
        free(buffer);

        arm_failure(k_copy);
        cbor_item_t *copied = cbor_copy(item);
        arm_failure(0);
        if (copied != nullptr) {
            cbor_decref(&copied);
        }

        arm_failure(k_copy_definite);
        cbor_item_t *copied_definite = cbor_copy_definite(item);
        arm_failure(0);
        if (copied_definite != nullptr) {
            cbor_decref(&copied_definite);
        }

        cbor_decref(&item);
    }
    return 0;
}
