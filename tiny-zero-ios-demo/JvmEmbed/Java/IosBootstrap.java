import java.io.ByteArrayOutputStream;
import java.io.OutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;

/**
 * App-side bootstrap helper for an embedded JVM program.
 *
 * The embedded program jar is used unmodified; this helper is compiled
 * separately and appended to java.class.path after it. The native bridge
 * registers nativeLog(String) and then calls redirect(), so everything the
 * JVM writes to stdout/stderr is forwarded line by line to the app UI.
 * Lines are forwarded raw, including ANSI escape sequences - the app side
 * parses SGR colors for display and stores a stripped plain-text log.
 */
public final class IosBootstrap {

    private IosBootstrap() {}

    /** Implemented in jvm_bridge.mm; forwards one raw output line to the app. */
    public static native void nativeLog(String line);

    /** Redirects System.out and System.err through nativeLog(). */
    public static void redirect() {
        LineForwarder fwd = new LineForwarder();
        System.setOut(new PrintStream(fwd, true));
        System.setErr(new PrintStream(fwd, true));
    }

    /** Splits a stream into lines and forwards each raw line via nativeLog(). */
    private static final class LineForwarder extends OutputStream {
        private final ByteArrayOutputStream buf = new ByteArrayOutputStream();

        @Override
        public synchronized void write(int b) {
            // Splitting on the raw bytes is UTF-8 safe: 0x0A/0x0D never occur
            // inside a multi-byte sequence.
            if (b == '\n') {
                flushLine();
            } else if (b != '\r') {
                buf.write(b);
            }
        }

        @Override
        public synchronized void write(byte[] b, int off, int len) {
            for (int i = 0; i < len; i++) {
                write(b[off + i]);
            }
        }

        private void flushLine() {
            if (buf.size() == 0) {
                return;
            }
            nativeLog(buf.toString(StandardCharsets.UTF_8));
            buf.reset();
        }
    }
}
