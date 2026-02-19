/*
 * Cross-language benchmark: Java — TreeMap (red-black tree) vs FAST FFI (JNI).
 *
 * Build JNI glue:
 *   javac -h . ../../bindings/java/FastTree.java
 *   gcc -shared -fPIC -o libfast_jni.so ../../bindings/java/fast_jni.c \
 *       -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" \
 *       -I../../include -L../../build -lfast
 *
 * Compile and run:
 *   javac -cp ../../bindings/java:. bench_java.java
 *   java -cp ../../bindings/java:. -Djava.library.path=. bench_java <tree_size> <num_queries>
 */

import java.util.TreeMap;
import java.util.Map;
import java.util.Random;

public class bench_java {

    static void emitJSON(String compiler, String method,
                         int treeSize, int numQueries, double sec) {
        double mqs = numQueries / sec / 1e6;
        double nsq = sec * 1e9 / numQueries;
        System.out.printf("{\"language\":\"java\",\"compiler\":\"%s\",\"method\":\"%s\"," +
                "\"tree_size\":%d,\"num_queries\":%d," +
                "\"total_sec\":%.4f,\"mqs\":%.2f,\"ns_per_query\":%.1f}%n",
                compiler, method, treeSize, numQueries, sec, mqs, nsq);
        System.out.flush();
    }

    public static void main(String[] args) {
        int treeSize = args.length > 0 ? Integer.parseInt(args[0]) : 1000000;
        int numQueries = args.length > 1 ? Integer.parseInt(args[1]) : 5000000;

        String javaVersion = System.getProperty("java.version");
        String vmName = System.getProperty("java.vm.name", "");
        String compiler = vmName.contains("OpenJDK") ? "openjdk-" + javaVersion
                        : "java-" + javaVersion;

        // Generate sorted keys
        int[] keys = new int[treeSize];
        for (int i = 0; i < treeSize; i++)
            keys[i] = i * 3 + 1;
        int maxKey = keys[treeSize - 1];

        // Generate random queries
        Random rng = new Random(42);
        int[] queries = new int[numQueries];
        for (int i = 0; i < numQueries; i++)
            queries[i] = rng.nextInt(maxKey + 1);

        int warmup = Math.min(numQueries, 100000);

        // --- FAST FFI (JNI) ---
        try (FastTree tree = FastTree.create(keys)) {
            long sink = 0;

            // JIT warmup
            for (int w = 0; w < 3; w++) {
                for (int i = 0; i < warmup; i++)
                    sink += tree.search(queries[i]);
            }

            long t0 = System.nanoTime();
            for (int i = 0; i < numQueries; i++)
                sink += tree.search(queries[i]);
            long t1 = System.nanoTime();
            double sec = (t1 - t0) / 1e9;
            emitJSON(compiler, "fast_ffi", treeSize, numQueries, sec);

            if (sink == Long.MIN_VALUE) System.err.println(sink);
        }

        // --- TreeMap (red-black tree) ---
        {
            TreeMap<Integer, Integer> treeMap = new TreeMap<>();
            for (int i = 0; i < treeSize; i++)
                treeMap.put(keys[i], i);

            long sink = 0;

            for (int w = 0; w < 3; w++) {
                for (int i = 0; i < warmup; i++) {
                    Map.Entry<Integer, Integer> entry = treeMap.floorEntry(queries[i]);
                    sink += (entry != null) ? entry.getValue() : -1;
                }
            }

            long t0 = System.nanoTime();
            for (int i = 0; i < numQueries; i++) {
                Map.Entry<Integer, Integer> entry = treeMap.floorEntry(queries[i]);
                sink += (entry != null) ? entry.getValue() : -1;
            }
            long t1 = System.nanoTime();
            double sec = (t1 - t0) / 1e9;
            emitJSON(compiler, "TreeMap", treeSize, numQueries, sec);

            if (sink == Long.MIN_VALUE) System.err.println(sink);
        }
    }
}
