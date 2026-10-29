import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;

import java.io.File;
import java.io.FileOutputStream;

/**
 * 设备端图标/名称导出器（由 Mac 端 app_process 拉起，运行在 shell uid）。
 * 用法：IconDump <输出目录> <包名> [包名...]
 * 输出：目录下 <pkg>.png；stdout 每行 "pkg\tlabel"
 */
public class IconDump {
    public static void main(String[] args) {
        try {
            android.os.Looper.prepareMainLooper();
            Class<?> at = Class.forName("android.app.ActivityThread");
            Object thread = at.getMethod("systemMain").invoke(null);
            Context ctx = (Context) at.getMethod("getSystemContext").invoke(thread);
            PackageManager pm = ctx.getPackageManager();
            String outDir = args[0];
            new File(outDir).mkdirs();
            for (int i = 1; i < args.length; i++) {
                String pkg = args[i];
                String label = pkg;
                try {
                    ApplicationInfo ai = pm.getApplicationInfo(pkg, 0);
                    CharSequence cs = pm.getApplicationLabel(ai);
                    if (cs != null && cs.length() > 0) label = cs.toString();
                } catch (Throwable ignored) { }
                try {
                    Drawable d = pm.getApplicationIcon(pkg);
                    int size = 192;
                    Bitmap bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
                    Canvas c = new Canvas(bmp);
                    d.setBounds(0, 0, size, size);
                    d.draw(c);
                    FileOutputStream fos = new FileOutputStream(new File(outDir, pkg + ".png"));
                    bmp.compress(Bitmap.CompressFormat.PNG, 100, fos);
                    fos.close();
                    System.out.println(pkg + "\t" + label);
                } catch (Throwable t) {
                    System.out.println(pkg + "\t" + label + "\tICON_FAIL");
                }
            }
        } catch (Throwable t) {
            t.printStackTrace();
        }
    }
}
