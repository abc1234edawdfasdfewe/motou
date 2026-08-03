package android.os;

/**
 * 编译期占位（stub）：方法体永远不会执行——运行时由 bootclasspath 里的真身
 * android.os.EinkManager（rk3576_ebook 实测存在）接管，dex 里这份只是让编译通过。
 * 签名来自真机 framework.jar 反射转储：
 *   getMode():String / setMode(String):void / init():int / kill():int
 *   standby():int / quitStandby():int / sendOneFullFrame():void
 *   enableTpWork(boolean):void / shutdownOrReboot(boolean):void
 *   static getEinkEnabled():boolean / static setEinkEnabled():void
 */
public class EinkManager {

    /** 刷新模式字符串常量（值来自 Rockchip api/current.txt，即写入 sys.ebook.mode 的值）。 */
    public static class EinkMode {
        public static final String EPD_AUTO = "0";
        public static final String EPD_FULL_GC16 = "2";
        public static final String EPD_A2 = "12";
        public static final String EPD_A2_DITHER = "13";
        public static final String EPD_DU = "14";
        public static final String EPD_DU4 = "15";
        public static final String EPD_A2_ENTER = "16";
        public static final String EPD_RESET = "17";
        public static final String EPD_AUTO_DU = "22";
        public static final String EPD_AUTO_DU4 = "23";
    }

    public EinkManager() {
        throw new RuntimeException("stub!");
    }

    public int init() {
        throw new RuntimeException("stub!");
    }

    public String getMode() {
        throw new RuntimeException("stub!");
    }

    public void setMode(String mode) {
        throw new RuntimeException("stub!");
    }

    public int standby() {
        throw new RuntimeException("stub!");
    }

    public int quitStandby() {
        throw new RuntimeException("stub!");
    }

    public int kill() {
        throw new RuntimeException("stub!");
    }

    public void sendOneFullFrame() {
        throw new RuntimeException("stub!");
    }

    public void enableTpWork(boolean enable) {
        throw new RuntimeException("stub!");
    }

    public void shutdownOrReboot(boolean reboot) {
        throw new RuntimeException("stub!");
    }

    public static boolean getEinkEnabled() {
        throw new RuntimeException("stub!");
    }

    public static void setEinkEnabled() {
        throw new RuntimeException("stub!");
    }
}
