import java.io.OutputStream;
import java.io.PrintStream;

/**
 * App-side bootstrap helper for the embedded vproxy demo.
 *
 * The embedded program is the stock, unmodified vproxy.jar; this helper is
 * compiled separately (support/build-java.sh) and appended to
 * java.class.path after it. The native bridge registers nativeLog(String)
 * and then calls redirect(), so everything the JVM writes to stdout/stderr
 * (vproxy's logger writes to stdout) is forwarded line by line to the app
 * UI. Lines are forwarded raw, including ANSI escape sequences - the app
 * side parses SGR colors for display and stores a stripped plain-text log.
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
