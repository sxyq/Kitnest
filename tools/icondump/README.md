# icons.dex（设备端图标渲染助手）

`apps/FrsetNext/Resources/bin/icons.dex` 的源码。App 会把 dex push 到
`/data/local/tmp/frset-icons.dex`，用 `app_process` 在手机上跑（shell uid，不装 APK、不要 root），
由 `PackageManager` 渲染真实图标并输出真实应用名。

## 为什么需要它

国产 App（微信/淘宝/抖音…）的 APK 资源名全部混淆，`unzip -l` 里搜不到 `ic_launcher`；
解析 AndroidManifest / resources.arsc 也不稳定。让系统自己渲染是唯一可靠路径。

## 重新编译

```bash
AJ=$HOME/Library/Android/sdk/platforms/android-35/android.jar
D8=$HOME/Library/Android/sdk/build-tools/34.0.0/d8
javac -source 1.8 -target 1.8 -bootclasspath "$AJ" -d out IconDump.java
"$D8" --lib "$AJ" --output out out/IconDump.class
cp out/classes.dex ../../apps/FrsetNext/Resources/bin/icons.dex
```

## 用法

```
CLASSPATH=/data/local/tmp/frset-icons.dex app_process /system/bin IconDump <输出目录> <包名...>
```

输出：目录下 `<pkg>.png`（192×192），stdout 每行 `pkg<TAB>label`。
