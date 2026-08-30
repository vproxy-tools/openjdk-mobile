import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.time.ZonedDateTime;
import java.util.Map;
import java.util.TreeMap;

/**
 * Tiny HTTP server used by the iOS demo.
 *
 * Listens on 127.0.0.1:<port> and answers every request with the same small
 * HTML page (JVM info, current system time and all System properties). Runs
 * on the embedded Tiny Zero JVM; the app passes the port as args[0].
 *
 * Error handling: every failure is reported through log(), which forwards the
 * full message (and exception class + message) to the app UI, so nothing
 * fails silently. Startup problems propagate out of main and are surfaced by
 * the native bridge; per-connection problems are logged and the server keeps
 * running.
 */
public class TinyHttpServer {

    private static volatile ServerSocket serverSocket;
    private static volatile long servedRequests = 0;
    private static volatile long startedAtMs;

    public static void main(String[] args) throws Exception {
        startedAtMs = System.currentTimeMillis();
        redirectStdoutStderr();

        int port = parsePort(args);
        serverSocket = new ServerSocket(port, 64, InetAddress.getByName("127.0.0.1"));
        log("main: listening on http://127.0.0.1:" + port);

        Thread heartbeat = new Thread(TinyHttpServer::heartbeatLoop, "heartbeat");
        heartbeat.setDaemon(true);
        heartbeat.start();

        // A plain server loop: no cooperative shutdown code. The host stops
        // the program with System.exit(0), exactly like killing a regular
        // java process on Linux/macOS.
        while (true) {
            // One broken connection (or a transient accept error) must not
            // take the server down; report it and keep serving.
            try (Socket socket = serverSocket.accept()) {
                serve(socket);
            } catch (Throwable t) {
                log("http: connection handler error: " + describe(t));
            }
        }
    }

    private static int parsePort(String[] args) {
        if (args.length < 1) {
            throw new IllegalArgumentException(
                    "缺少端口参数(usage: TinyHttpServer <port>,例如 8080)");
        }
        try {
            return Integer.parseInt(args[0].trim());
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException(
                    "端口参数无效:\"" + args[0] + "\" 不是数字(usage: TinyHttpServer <port>)");
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

            byte[] body = buildPage().getBytes(StandardCharsets.UTF_8);

            OutputStream out = socket.getOutputStream();
            out.write(("HTTP/1.1 200 OK\r\n"
                    + "Content-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: " + body.length + "\r\n"
                    + "Connection: close\r\n"
                    + "\r\n").getBytes(StandardCharsets.US_ASCII));
            out.write(body);
            out.flush();
        } catch (IOException e) {
            log("http: error handling connection: " + describe(e));
        }
    }

    /** Exception + full cause chain, so the real root failure reaches the UI. */
    private static String describe(Throwable t) {
        StringBuilder d = new StringBuilder(t.toString());
        for (Throwable c = t.getCause(); c != null; c = c.getCause()) {
            d.append("\n  caused by: ").append(c);
        }
        return d.toString();
    }

    // ------------------------------------------------------------------ page

    /** The single page served: JVM info, system time and System properties. */
    private static String buildPage() {
        long nowMs = System.currentTimeMillis();
        StringBuilder p = new StringBuilder(12 * 1024);
        p.append("<html>\n")
         .append("<head><meta charset=\"utf-8\"><title>Tiny Zero on iOS</title></head>\n")
         .append("<body style=\"font-family:-apple-system;background:#111;color:#eee;margin:3em\">\n")
         .append("<h1>Hello from the Tiny Zero JVM &#x1f34f;</h1>\n")
         .append("<p>This page was served by an embedded OpenJDK Zero JVM running ")
         .append(escape(System.getProperty("java.version", "?")))
         .append(" inside an iOS app.</p>\n")
         .append("<p>servedRequests=").append(servedRequests)
         .append(", uptime=").append((nowMs - startedAtMs) / 1000).append("s</p>\n")
         .append("<h2>System time</h2>\n")
         .append("<p><code>").append(escape(ZonedDateTime.now().toString()))
         .append("</code> <span style=\"color:#888\">(epoch ms: ").append(nowMs)
         .append(")</span></p>\n")
         .append("<h2>System.getProperties()</h2>\n")
         .append("<table style=\"border-collapse:collapse;font-size:14px\">\n");
        for (Map.Entry<Object, Object> e : new TreeMap<>(System.getProperties()).entrySet()) {
            p.append("<tr><td style=\"padding:2px 12px 2px 0;color:#8dd;white-space:nowrap\">")
             .append(escape(String.valueOf(e.getKey())))
             .append("</td><td style=\"padding:2px 0;word-break:break-all\">")
             .append(escape(String.valueOf(e.getValue())))
             .append("</td></tr>\n");
        }
        p.append("</table>\n</body>\n</html>\n");
        return p.toString();
    }

    private static String escape(String s) {
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    /** Reads request bytes up to the end of the request head; returns the request line. */
    private static String readRequestHead(InputStream in) throws IOException {
        ByteArrayOutputStream head = new ByteArrayOutputStream();
        byte[] buf = new byte[1024];
        // Bytes already scanned for the end-of-head marker; the last 3 bytes
        // are rescanned each round so a "\r\n\r\n" split across reads is seen.
        int scanned = 0;
        while (head.size() < 16 * 1024) {
            int n = in.read(buf);
            if (n < 0) {
                break;
            }
            head.write(buf, 0, n);
            int from = Math.max(0, scanned - 3);
            String window = new String(head.toByteArray(), from, head.size() - from,
                    StandardCharsets.US_ASCII);
            if (window.indexOf("\r\n\r\n") >= 0 || window.indexOf("\n\n") >= 0) {
                break;
            }
            scanned = head.size();
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

    /** Splits a stream into lines and forwards each through nativeLog(). */
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
