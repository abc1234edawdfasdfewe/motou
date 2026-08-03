package android.os;

/**
 * 编译期占位（stub）：真身在 bootclasspath（rk3576_ebook 实测存在 IEinkManager 系统服务，
 * service list 可见 "eink"）。运行时 parent-first 加载真身，此文件仅为编译通过。
 */
public final class ServiceManager {

    public static IBinder getService(String name) {
        throw new RuntimeException("stub!");
    }
}
