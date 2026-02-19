// Cross-language benchmark: Rust — BTreeMap (B-tree) vs FAST FFI.
//
// Compile:
//   rustc -O --edition 2021 -L ../../build -l fast bench_rust.rs -o bench_rust

use std::collections::BTreeMap;
use std::time::Instant;

// Inline FFI declarations (avoids Cargo dependency)
#[repr(C)]
struct FastTreeOpaque {
    _private: [u8; 0],
}

extern "C" {
    fn fast_create(keys: *const i32, n: usize) -> *mut FastTreeOpaque;
    fn fast_destroy(tree: *mut FastTreeOpaque);
    fn fast_search(tree: *const FastTreeOpaque, key: i32) -> i64;
}

fn emit_json(compiler: &str, method: &str, tree_size: usize, num_queries: usize, sec: f64) {
    let mqs = num_queries as f64 / sec / 1e6;
    let nsq = sec * 1e9 / num_queries as f64;
    println!(
        "{{\"language\":\"rust\",\"compiler\":\"{}\",\"method\":\"{}\",\
         \"tree_size\":{},\"num_queries\":{},\
         \"total_sec\":{:.4},\"mqs\":{:.2},\"ns_per_query\":{:.1}}}",
        compiler, method, tree_size, num_queries, sec, mqs, nsq
    );
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let tree_size: usize = args.get(1).and_then(|s| s.parse().ok()).unwrap_or(1_000_000);
    let num_queries: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(5_000_000);

    let compiler = "rustc";

    // Generate sorted keys
    let keys: Vec<i32> = (0..tree_size).map(|i| (i as i32) * 3 + 1).collect();
    let max_key = keys[tree_size - 1];

    // Generate random queries (simple LCG seeded with 42)
    let mut rng_state: u64 = 42;
    let queries: Vec<i32> = (0..num_queries)
        .map(|_| {
            rng_state = rng_state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((rng_state >> 33) as i32).rem_euclid(max_key + 1)
        })
        .collect();

    let warmup = num_queries.min(100_000);

    // --- FAST FFI ---
    unsafe {
        let tree = fast_create(keys.as_ptr(), keys.len());
        assert!(!tree.is_null());

        let mut sink: i64 = 0;
        for i in 0..warmup {
            sink = sink.wrapping_add(fast_search(tree, queries[i]));
        }

        let t0 = Instant::now();
        for i in 0..num_queries {
            sink = sink.wrapping_add(fast_search(tree, queries[i]));
        }
        let elapsed = t0.elapsed().as_secs_f64();
        emit_json(compiler, "fast_ffi", tree_size, num_queries, elapsed);

        fast_destroy(tree);
        std::hint::black_box(sink);
    }

    // --- BTreeMap (B-tree) ---
    {
        let mut btree = BTreeMap::new();
        for (i, &k) in keys.iter().enumerate() {
            btree.insert(k, i);
        }

        let mut sink: i64 = 0;
        for i in 0..warmup {
            let idx = btree.range(..=queries[i]).next_back()
                .map(|(_, &v)| v as i64)
                .unwrap_or(-1);
            sink = sink.wrapping_add(idx);
        }

        let t0 = Instant::now();
        for i in 0..num_queries {
            let idx = btree.range(..=queries[i]).next_back()
                .map(|(_, &v)| v as i64)
                .unwrap_or(-1);
            sink = sink.wrapping_add(idx);
        }
        let elapsed = t0.elapsed().as_secs_f64();
        emit_json(compiler, "BTreeMap", tree_size, num_queries, elapsed);

        std::hint::black_box(sink);
    }
}
