package android.os;

/** Build constants describing the Android release the host emulates. */
public class Build {
    public static final String BRAND = "google";
    public static final String MANUFACTURER = "Google";
    public static final String MODEL = "Pixel 6";
    public static final String DEVICE = "oriole";
    public static final String PRODUCT = "oriole";
    public static final String HARDWARE = "tachi";
    public static final String BOARD = "tachi";
    public static final String ID = "tachi-host";
    public static final String DISPLAY = "tachi-host";
    public static final String FINGERPRINT = "google/oriole/oriole:11/tachi-host/1:user/release-keys";
    public static final String TAGS = "release-keys";
    public static final String TYPE = "user";
    public static final String USER = "tachi";
    public static final String HOST = "tachi";
    public static final String[] SUPPORTED_ABIS = {"arm64-v8a"};

    public static class VERSION {
        public static final String RELEASE = "11";
        public static final String INCREMENTAL = "1";
        public static final String CODENAME = "REL";
        public static final int SDK_INT = 30;
        public static final String SDK = "30";
        public static final String SECURITY_PATCH = "2021-01-01";
    }

    public static class VERSION_CODES {
        public static final int LOLLIPOP = 21;
        public static final int LOLLIPOP_MR1 = 22;
        public static final int M = 23;
        public static final int N = 24;
        public static final int N_MR1 = 25;
        public static final int O = 26;
        public static final int O_MR1 = 27;
        public static final int P = 28;
        public static final int Q = 29;
        public static final int R = 30;
        public static final int S = 31;
        public static final int S_V2 = 32;
        public static final int TIRAMISU = 33;
        public static final int UPSIDE_DOWN_CAKE = 34;
    }
}
