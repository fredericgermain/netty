// Self-contained UDP echo on loopback: N sender threads, N echo threads, same JVM.
//
// One rung above Busy. This adds the syscall pattern QUIC actually uses (sendto/recvfrom on
// datagram sockets) while excluding quiche, TLS, netty and the allocator-heavy QUIC path. If Busy
// is GREEN and this is RED, the trigger is datagram syscalls rather than anything above them.
import java.net.*;
import java.nio.*;

public class Udp {
    public static void main(String[] a) throws Exception {
        int threads = Integer.parseInt(System.getProperty("t", "4"));
        int payload = Integer.parseInt(System.getProperty("p", "1024"));
        for (int i = 0; i < threads; i++) {
            final int base = 21000 + i * 2;
            // Echo side: receives and sends straight back.
            DatagramSocket echo = new DatagramSocket(base);
            Thread e = new Thread(() -> {
                byte[] buf = new byte[65535];
                DatagramPacket p = new DatagramPacket(buf, buf.length);
                try {
                    while (true) { echo.receive(p); echo.send(p); }
                } catch (Exception ignored) { }
            });
            e.setDaemon(true); e.start();

            // Driver side: one outstanding datagram at a time, so this is a request/response loop
            // rather than a flood, matching the closed-loop shape of the QUIC test.
            DatagramSocket drv = new DatagramSocket(base + 1);
            drv.connect(InetAddress.getByName("127.0.0.1"), base);
            Thread d = new Thread(() -> {
                byte[] out = new byte[payload];
                byte[] in = new byte[65535];
                DatagramPacket sp = new DatagramPacket(out, out.length);
                DatagramPacket rp = new DatagramPacket(in, in.length);
                try {
                    while (true) { drv.send(sp); drv.receive(rp); }
                } catch (Exception ignored) { }
            });
            d.setDaemon(true); d.start();
        }
        Thread.sleep(600_000);
    }
}
