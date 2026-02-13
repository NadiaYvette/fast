/*
 * OCaml C stubs for the FAST search tree library.
 *
 * These stubs bridge OCaml values to the C fast_* functions.
 * Compile: ocamlopt fast_stubs.c fast.ml -cclib -lfast
 */

#include <caml/mlvalues.h>
#include <caml/memory.h>
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <fast.h>

/* Custom block operations for fast_tree_t pointer */
static struct custom_operations fast_tree_ops = {
    "fast_tree_t",
    custom_finalize_default,
    custom_compare_default,
    custom_hash_default,
    custom_serialize_default,
    custom_deserialize_default,
    custom_compare_ext_default,
    custom_fixed_length_default
};

#define FastTree_val(v) (*((fast_tree_t **) Data_custom_val(v)))

CAMLprim value caml_fast_create(value keys, value n_val)
{
    CAMLparam2(keys, n_val);
    CAMLlocal1(result);

    int n = Int_val(n_val);
    int32_t *buf = (int32_t *)malloc(n * sizeof(int32_t));
    if (!buf) caml_failwith("fast_create: allocation failed");

    for (int i = 0; i < n; i++)
        buf[i] = Int32_val(Field(keys, i));

    fast_tree_t *tree = fast_create(buf, (size_t)n);
    free(buf);

    if (!tree) caml_failwith("fast_create failed");

    result = caml_alloc_custom(&fast_tree_ops, sizeof(fast_tree_t *), 0, 1);
    FastTree_val(result) = tree;
    CAMLreturn(result);
}

CAMLprim value caml_fast_destroy(value tree_val)
{
    CAMLparam1(tree_val);
    fast_tree_t *tree = FastTree_val(tree_val);
    if (tree) {
        fast_destroy(tree);
        FastTree_val(tree_val) = NULL;
    }
    CAMLreturn(Val_unit);
}

CAMLprim value caml_fast_search(value tree_val, value key_val)
{
    CAMLparam2(tree_val, key_val);
    fast_tree_t *tree = FastTree_val(tree_val);
    int32_t key = Int32_val(key_val);
    int64_t result = fast_search(tree, key);
    CAMLreturn(caml_copy_int64(result));
}

CAMLprim value caml_fast_search_lower_bound(value tree_val, value key_val)
{
    CAMLparam2(tree_val, key_val);
    fast_tree_t *tree = FastTree_val(tree_val);
    int32_t key = Int32_val(key_val);
    int64_t result = fast_search_lower_bound(tree, key);
    CAMLreturn(caml_copy_int64(result));
}

CAMLprim value caml_fast_size(value tree_val)
{
    CAMLparam1(tree_val);
    fast_tree_t *tree = FastTree_val(tree_val);
    CAMLreturn(Val_int((int)fast_size(tree)));
}

CAMLprim value caml_fast_key_at(value tree_val, value idx_val)
{
    CAMLparam2(tree_val, idx_val);
    fast_tree_t *tree = FastTree_val(tree_val);
    int32_t key = fast_key_at(tree, (size_t)Int_val(idx_val));
    CAMLreturn(caml_copy_int32(key));
}
