import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;
import java.nio.charset.StandardCharsets;

/**
 * Tiny HTTP server used by the iOS demo.
 *
 * Listens on 127.0.0.1:<port> and answers every request with the same small
 * HTML page. Runs on the embedded Tiny Zero JVM; the app passes the port as
 * args[0].
 *
 * Output convention: everything logged through log() also goes to the
 * redirected System.out, and every line is forwarded to the native side via
 * nativeLog() so the app can display it. A daemon heartbeat thread reports
 * liveness every few seconds, which also serves as the "still running"
 * indicator after the app is relaunched (the log file persists on disk).
 */
public class TinyHttpServer {

    private static volatile ServerSocket serverSocket;
    private static volatile long servedRequests = 0;
    private static volatile long startedAtMs;

    public static void main(String[] args) throws Exception {
        startedAtMs = System.currentTimeMillis();
        redirectStdoutStderr();
        log("main: starting, pid-like-uptime base set");

        int port = Integer.parseInt(args[0]);
        serverSocket = new ServerSocket(port, 64, InetAddress.getByName("127.0.0.1"));
        log("main: listening on http://127.0.0.1:" + port);

        Thread heartbeat = new Thread(TinyHttpServer::heartbeatLoop, "heartbeat");
        heartbeat.setDaemon(true);
        heartbeat.start();

        // A plain server loop: no cooperative shutdown code. The host stops
        // the program with System.exit(0), exactly like killing a regular
        // java process on Linux/macOS.
        while (true) {
            Socket socket = serverSocket.accept();
            try (Socket s = socket) {
                serve(s);
            }
        }
    }

    private static void heartbeatLoop() {
        while (true) {
            try {
                Thread.sleep(5000);
            } catch (InterruptedException e) {
                return;
            }
            long upS = (System.currentTimeMillis() - startedAtMs) / 1000;
            Runtime rt = Runtime.getRuntime();
            log(String.format(
                    "heartbeat: uptime=%ds servedRequests=%d heapUsed=%dK heapMax=%dK",
                    upS, servedRequests,
                    (rt.totalMemory() - rt.freeMemory()) / 1024, rt.maxMemory() / 1024));
        }
    }

    private static void serve(Socket socket) {
        try {
            socket.setSoTimeout(5000);
            String firstLine = readRequestHead(socket.getInputStream());
            servedRequests++;
            log("http: " + socket.getInetAddress().getHostAddress() + " \""
                    + (firstLine == null ? "<no request line>" : firstLine) + "\"");

            byte[] body = ("<html>\n"
                    + "<head><meta charset=\"utf-8\"><title>Tiny Zero on iOS</title></head>\n"
                    + "<body style=\"font-family:-apple-system;background:#111;color:#eee;margin:3em\">\n"
                    + "<h1>Hello from the Tiny Zero JVM &#x1f34f;</h1>\n"
                    + "<p>This page was served by an embedded OpenJDK Zero JVM running "
                    + System.getProperty("java.version")
                    + " inside an iOS app.</p>\n"
                    + "<p>servedRequests=" + servedRequests
                    + ", uptime=" + ((System.currentTimeMillis() - startedAtMs) / 1000) + "s</p>\n"
                    + "</body>\n</html>\n").getBytes(StandardCharsets.UTF_8);

            OutputStream out = socket.getOutputStream();
            out.write(("HTTP/1.1 200 OK\r\n"
                    + "Content-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: " + body.length + "\r\n"
                    + "Connection: close\r\n"
                    + "\r\n").getBytes(StandardCharsets.US_ASCII));
            out.write(body);
            out.flush();
        } catch (IOException e) {
            log("http: error handling connection: " + e);
        }
    }

    /** Reads request bytes up to the end of the request head; returns the request line. */
    private static String readRequestHead(InputStream in) throws IOException {
        ByteArrayOutputStream head = new ByteArrayOutputStream();
        byte[] buf = new byte[1024];
        int total = 0;
        while (total < 16 * 1024) {
            int n = in.read(buf);
            if (n < 0) {
                break;
            }
            head.write(buf, 0, n);
            total += n;
            String s = new String(head.toByteArray(), StandardCharsets.US_ASCII);
            if (s.contains("\r\n\r\n") || s.contains("\n\n")) {
                break;
            }
        }
        String all = new String(head.toByteArray(), StandardCharsets.US_ASCII);
        int nl = all.indexOf('\n');
        return nl < 0 ? all.trim() : all.substring(0, nl).trim();
    }

    // ------------------------------------------------------------------ logging

    /** Implemented in jvm_bridge.mm; forwards one line to the app UI and log file. */
    static native void nativeLog(String line);

    static void log(String message) {
        // stdout is redirected to LineForwarder (which forwards via
        // nativeLog); printing once is enough — a direct nativeLog call here
        // used to duplicate every line.
        System.out.println(System.currentTimeMillis() + " " + message);
    }

    private static void redirectStdoutStderr() {
        LineForwarder fwd = new LineForwarder();
        System.setOut(new PrintStream(fwd, true));
        System.setErr(new PrintStream(fwd, true));
    }

    /** Splits a stream into lines and forwards each through log(). */
    private static final class LineForwarder extends java.io.OutputStream {
        private final StringBuilder sb = new StringBuilder();

        @Override
        public synchronized void write(int b) {
            char c = (char) (b & 0xFF);
            if (c == '\n') {
                flushLine();
            } else if (c != '\r') {
                sb.append(c);
            }
        }

        @Override
        public synchronized void write(byte[] b, int off, int len) {
            for (int i = 0; i < len; i++) {
                write(b[off + i]);
            }
        }

        private void flushLine() {
            if (sb.length() == 0) {
                return;
            }
            nativeLog(sb.toString());
            sb.setLength(0);
        }
    }
}
