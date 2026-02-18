/**
 * Java bindings for the FAST (Fast Architecture Sensitive Tree) library.
 *
 * Uses JNI to call the native C library. Requires the JNI glue in
 * fast_jni.c to be compiled into a shared library (libfast_jni.so).
 *
 * Build the JNI glue:
 *   javac -h . FastTree.java
 *   gcc -shared -fPIC -o libfast_jni.so fast_jni.c \
 *       -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" \
 *       -I../../include -L../../build -lfast
 *
 * Usage:
 *   int[] keys = {1, 3, 5, 7, 9};
 *   try (FastTree tree = FastTree.create(keys)) {
 *       long idx = tree.search(5);   // returns 2
 *       long lb  = tree.lowerBound(4); // returns 1
 *   }
 */
public class FastTree implements AutoCloseable {

    static {
        System.loadLibrary("fast_jni");
    }

    private long nativePtr;

    private FastTree(long ptr) {
        this.nativePtr = ptr;
    }

    /**
     * Build a FAST tree from a sorted array of 32-bit keys.
     *
     * @param keys sorted int array
     * @return a new FastTree
     * @throws OutOfMemoryError if native allocation fails
     */
    public static FastTree create(int[] keys) {
        long ptr = nativeCreate(keys, keys.length);
        if (ptr == 0) {
            throw new OutOfMemoryError("fast_create failed");
        }
        return new FastTree(ptr);
    }

    /**
     * Search for the largest key &lt;= query.
     *
     * @return index into the original sorted array, or -1 if query &lt; all keys
     */
    public long search(int key) {
        return nativeSearch(nativePtr, key);
    }

    /**
     * Find the first key &gt;= query.
     *
     * @return index, or size() if query &gt; all keys
     */
    public long lowerBound(int key) {
        return nativeLowerBound(nativePtr, key);
    }

    /** Number of keys in the tree. */
    public long size() {
        return nativeSize(nativePtr);
    }

    /** Key at the given sorted index. */
    public int keyAt(long index) {
        return nativeKeyAt(nativePtr, index);
    }

    @Override
    public void close() {
        if (nativePtr != 0) {
            nativeDestroy(nativePtr);
            nativePtr = 0;
        }
    }

    // JNI native methods
    private static native long nativeCreate(int[] keys, int n);
    private static native void nativeDestroy(long ptr);
    private static native long nativeSearch(long ptr, int key);
    private static native long nativeLowerBound(long ptr, int key);
    private static native long nativeSize(long ptr);
    private static native int  nativeKeyAt(long ptr, long index);
}
