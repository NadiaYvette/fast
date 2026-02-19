#!/usr/bin/env Rscript
# Cross-language benchmark: R — findInterval vs FAST FFI (.Call).
#
# Run: Rscript bench_r.R <tree_size> <num_queries>

args <- commandArgs(trailingOnly = TRUE)
tree_size <- if (length(args) >= 1) as.integer(args[1]) else 1000000L
num_queries <- if (length(args) >= 2) as.integer(args[2]) else 500000L  # R is slow; default lower

# Detect script directory robustly (works with both Rscript and source())
get_script_dir <- function() {
  args <- commandArgs(trailingOnly = FALSE)
  m <- regmatches(args, regexpr("(?<=^--file=).+", args, perl = TRUE))
  if (length(m) > 0) return(dirname(normalizePath(m[1])))
  return(".")
}
script_dir <- get_script_dir()

# Load libfast
lib_paths <- c(
  file.path(script_dir, "..", "..", "build", "libfast.so"),
  normalizePath(file.path(getwd(), "build", "libfast.so"), mustWork = FALSE),
  "/usr/local/lib/libfast.so"
)
loaded <- FALSE
for (p in lib_paths) {
  if (file.exists(p)) {
    dyn.load(p)
    loaded <- TRUE
    break
  }
}
if (!loaded) dyn.load("libfast.so")

emit_json <- function(method, tree_size, num_queries, sec) {
  mqs <- num_queries / sec / 1e6
  nsq <- sec * 1e9 / num_queries
  compiler <- paste0("R-", R.version$major, ".", R.version$minor)
  cat(sprintf('{"language":"r","compiler":"%s","method":"%s","tree_size":%d,"num_queries":%d,"total_sec":%.4f,"mqs":%.2f,"ns_per_query":%.1f}\n',
              compiler, method, tree_size, num_queries, sec, mqs, nsq))
  flush(stdout())
}

# Generate sorted keys
keys <- as.integer(seq(1L, by = 3L, length.out = tree_size))
max_key <- keys[tree_size]

# Generate random queries
set.seed(42)
queries <- sample.int(max_key + 1L, num_queries, replace = TRUE) - 1L

warmup <- min(num_queries, 10000L)

# --- FAST FFI ---
tree_ptr <- .Call("fast_create", keys, as.integer(tree_size))

for (i in seq_len(warmup)) {
  .Call("fast_search", tree_ptr, queries[i])
}

t0 <- proc.time()["elapsed"]
sink <- 0L
for (i in seq_len(num_queries)) {
  sink <- sink + .Call("fast_search", tree_ptr, queries[i])
}
elapsed <- proc.time()["elapsed"] - t0
emit_json("fast_ffi", tree_size, num_queries, as.numeric(elapsed))

.Call("fast_destroy", tree_ptr)

# --- findInterval ---
for (i in seq_len(warmup)) {
  findInterval(queries[i], keys)
}

t0 <- proc.time()["elapsed"]
sink <- 0L
for (i in seq_len(num_queries)) {
  idx <- findInterval(queries[i], keys)
  sink <- sink + idx - 1L  # findInterval returns 1-based; convert to 0-based
}
elapsed <- proc.time()["elapsed"] - t0
emit_json("findInterval", tree_size, num_queries, as.numeric(elapsed))
