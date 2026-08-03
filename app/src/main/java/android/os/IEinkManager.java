package android.os;

/**
 * 编译期占位（stub）：真身在 bootclasspath。方法签名来自真机 framework.jar：
 * EinkManager.setMode 内部调用 IEinkManager.setProperty(String, String)；
 * 接口里还有 getProperty / setMode / getMode / setGlobalEpdMode / getModelist /
 * setEinkRefreshFrequency / getEinkRefreshFrequency / clearEinkAppCache 等，
 * 此处只声明用到的两个。
 */
public interface IEinkManager extends IInterface {

    void setProperty(String key, String value) throws RemoteException;

    String getProperty(String key) throws RemoteException;

    abstract class Stub extends Binder implements IEinkManager {

        public static IEinkManager asInterface(IBinder binder) {
            throw new RuntimeException("stub!");
        }
    }
}
