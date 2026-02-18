/*
 * JNI glue for the FAST search tree library.
 *
 * Bridges Java native method declarations in FastTree.java to the
 * C fast_* functions.
 *
 * Build:
 *   javac -h . FastTree.java
 *   gcc -shared -fPIC -o libfast_jni.so fast_jni.c \
 *       -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" \
 *       -I../../include -L../../build -lfast
 */

#include <jni.h>
#include <fast.h>

JNIEXPORT jlong JNICALL Java_FastTree_nativeCreate(
    JNIEnv *env, jclass cls, jintArray keys, jint n)
{
    jint *buf = (*env)->GetIntArrayElements(env, keys, NULL);
    if (!buf) return 0;

    fast_tree_t *tree = fast_create((const int32_t *)buf, (size_t)n);
    (*env)->ReleaseIntArrayElements(env, keys, buf, JNI_ABORT);

    return (jlong)(uintptr_t)tree;
}

JNIEXPORT void JNICALL Java_FastTree_nativeDestroy(
    JNIEnv *env, jclass cls, jlong ptr)
{
    if (ptr)
        fast_destroy((fast_tree_t *)(uintptr_t)ptr);
}

JNIEXPORT jlong JNICALL Java_FastTree_nativeSearch(
    JNIEnv *env, jclass cls, jlong ptr, jint key)
{
    return (jlong)fast_search((const fast_tree_t *)(uintptr_t)ptr, (int32_t)key);
}

JNIEXPORT jlong JNICALL Java_FastTree_nativeLowerBound(
    JNIEnv *env, jclass cls, jlong ptr, jint key)
{
    return (jlong)fast_search_lower_bound(
        (const fast_tree_t *)(uintptr_t)ptr, (int32_t)key);
}

JNIEXPORT jlong JNICALL Java_FastTree_nativeSize(
    JNIEnv *env, jclass cls, jlong ptr)
{
    return (jlong)fast_size((const fast_tree_t *)(uintptr_t)ptr);
}

JNIEXPORT jint JNICALL Java_FastTree_nativeKeyAt(
    JNIEnv *env, jclass cls, jlong ptr, jlong index)
{
    return (jint)fast_key_at((const fast_tree_t *)(uintptr_t)ptr, (size_t)index);
}
