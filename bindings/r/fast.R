# R bindings for the FAST search tree library.
#
# Usage:
#   source("fast.R")
#   tree <- fast_create(c(1L, 3L, 5L, 7L, 9L))
#   fast_search(tree, 5L)         # returns 2
#   fast_search_lower_bound(tree, 4L)  # returns 1
#   fast_destroy(tree)

.fast_lib_loaded <- FALSE

fast_load_library <- function() {
  if (.fast_lib_loaded) return(invisible(NULL))

  lib_paths <- c(
    file.path(dirname(sys.frame(1)$ofile %||% "."), "..", "..", "build", "libfast.so"),
    "/usr/local/lib/libfast.so",
    "/usr/lib/libfast.so"
  )

  for (path in lib_paths) {
    if (file.exists(path)) {
      dyn.load(path)
      .fast_lib_loaded <<- TRUE
      return(invisible(NULL))
    }
  }

  # Try system default
  dyn.load("libfast.so")
  .fast_lib_loaded <<- TRUE
}

fast_create <- function(keys) {
  fast_load_library()
  stopifnot(is.integer(keys), length(keys) > 0)
  .Call("fast_create", keys, as.integer(length(keys)))
}

fast_destroy <- function(tree) {
  invisible(.Call("fast_destroy", tree))
}

fast_search <- function(tree, key) {
  .Call("fast_search", tree, as.integer(key))
}

fast_search_lower_bound <- function(tree, key) {
  .Call("fast_search_lower_bound", tree, as.integer(key))
}

fast_size <- function(tree) {
  .Call("fast_size", tree)
}

fast_key_at <- function(tree, index) {
  .Call("fast_key_at", tree, as.integer(index))
}
