// Pure CPU, no I/O, no allocation in the hot loop.
//
// The floor of the minimisation ladder. If this is already RED then musl's context-switch excess
// has nothing to do with networking or the allocator and is a property of running N busy threads,
// which would make every networking explanation a red herring.
public class Busy {
    public static void main(String[] a) throws Exception {
        int threads = Integer.parseInt(System.getProperty("t", "4"));
        for (int i = 0; i < threads; i++) {
            Thread th = new Thread(() -> {
                double x = 1.0;
                // Volatile-free, allocation-free spin. The sink keeps the JIT from eliminating it.
                while (!Thread.currentThread().isInterrupted()) {
                    for (int k = 0; k < 1_000_000; k++) x = x * 1.0000001 + 1e-9;
                    SINK += x;
                }
            });
            th.setDaemon(true);
            th.start();
        }
        Thread.sleep(600_000);
    }
    static volatile double SINK;
}
