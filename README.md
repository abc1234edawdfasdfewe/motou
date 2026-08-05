# 墨投（MoTou）

墨水屏内容投送 APP —— 不是镜像投屏，而是"电脑端排版、设备端即看"的局域网内容推送。

- 总体架构与设计决策：见 [技术方案.md](技术方案.md)
- M1 实现蓝图与验收标准：见 [M1开发说明.md](M1开发说明.md)
- iOS 原生发送端：见 [ios/README.md](ios/README.md)

## 当前能力

**M1（排版通道）**：文字投送（拖拽选中文字 / Ctrl+V / 输入框 / txt·md 文件）、CSS 多列整屏分页、点按翻页（左 35% 上一页 / 右 35% 下一页 / 中间切换页脚）、电脑端遥控翻页与页码同步、断线自动重连、前台服务常驻。排版参数随屏宽等比缩放（正文 ≈ 屏宽dp/32，每行约 28 汉字；边距 ≈ 屏宽 6%），不依赖经常虚报的 xdpi；`FONT_SCALE` 常量预留设备端一键调字号（M4）。

**M2（位图通道）**：

- 图片拖入 / 截图粘贴 → Canvas 按设备物理分辨率出图 → Floyd–Steinberg 灰度抖动（Web Worker，按 hello 上报的灰阶数量化）→ PNG 二进制帧 → 设备整页直显
- PDF 拖入 → PDF.js 分页渲染（页面比例适配、居中留白）→ 按需渲染 + 预取窗口（当前页 -1…+2）→ 双向翻页同步
- 设备端位图会话：±3 页缓存窗口自动回收、缺页回请电脑端按需补页、点按翻页、clear 回待机页
- 协议升级 v2：`content.begin` / `page`（JSON + 紧随二进制帧）/ `rendered` / `clear`，hello 新增 `renderer: ["html","bitmap"]`，未知 type 仍静默忽略

**M3（网页与 docx）**：

- `POST /fetch` 抓取代理（设备端 HttpURLConnection，解浏览器 CORS；跟随重定向、尊重 charset、5MB/15s 上限）→ 发送页 Readability 提取正文 → 白名单清洗（剔脚本/样式/iframe，剥全部原始属性，仅保留 img[src]/a[href]）→ 排版通道上屏
- docx 拖入 → mammoth.js 转干净 HTML → 同样白名单清洗 → 排版通道上屏，标题取文件名
- 发送页历史记录（localStorage 存最近 10 条排版内容，含标题/正文/类型/时间），点击即重投
- 网址拖拽与粘贴自动识别（http(s):// 开头即走正文提取，失败时提示复制文字直投）

## 三端可读文档支持（Android / Web / iOS）

下表指的是把文档提取为安全的语义 HTML，再走排版通道投送。Web 端是由墨水屏设备内置 HTTP 服务提供的发送页，Android 和 iOS 是两个原生发送端。

| 格式 | Android 发送端 | Web 发送端 | iOS 发送端 | 投送结果 |
| --- | --- | --- | --- | --- |
| Markdown（`.md` / `.markdown`） | 支持 | 支持 | 支持 | 标题、段落、列表、引用、代码块等；GFM 扩展细节因解析器而异 |
| EPUB（`.epub`） | 支持 | 支持 | 支持 | 按 OPF / spine 阅读顺序合并章节 |
| MOBI / AZW（`.mobi` / `.azw`） | 支持 | 支持 | 支持 | 提取书名和正文；仅处理无 DRM 副本 |
| AZW3 / KF8（`.azw3`） | 支持¹ | 支持¹ | 支持¹ | 章节正文；仅处理无 DRM 且压缩方式受支持的副本 |
| Word（`.doc` / `.docx`） | 支持 | 支持 | 支持 | 标题、段落、列表、表格等可读内容 |
| PowerPoint（`.ppt` / `.pptx`） | 支持 | 支持 | 支持 | 按幻灯片顺序提取标题和文字 |
| Excel（`.xls` / `.xlsx`） | 支持 | 支持 | 支持 | 按工作表提取单元格显示值并转为表格 |

¹ Android 与 iOS 当前支持未压缩或 PalmDOC 压缩的 MOBI/KF8 文本记录；HUFF/CDIC、Topaz/TPZ 等未支持变体会显式报错。复杂的 FDST/SKEL/FRAG 重组与固定版式 KF8 仍属于尽力提取，必要时建议转为无 DRM EPUB；Web 端解析范围更广，但也不保证兼容所有厂商扩展。

### 解析边界与安全策略

- 这是“可读内容提取”，不是 Word / PowerPoint / Excel 的保真渲染。原字体、页面几何、母版、动画、图表、宏、公式计算行为、嵌入 OLE 对象等不保留。
- 只有扫描页或截图、没有可提取文字层的文档，不会在导入时自动 OCR；可先用发送端的 OCR 功能识别后再投送。
- 密码保护、Office 加密、EPUB 内容加密和 Kindle DRM 会被拒绝；墨投不解密、不绕过 DRM。请从内容提供方获取无 DRM 副本，或在原应用中另存为未加密文件。
- 损坏档案、极端压缩比、过多 ZIP 条目、无正文或不支持的压缩/编码会明确失败，不会将未清洗的 HTML 直接送入阅读器。
- Markdown 建议保存为 UTF-8；三端都处理 UTF-8 BOM，原生端还支持带 BOM 的 UTF-16。对损坏字节或其他旧编码的容错可能因平台而异。

### 保护性大小上限

| 发送端 | 当前边界 |
| --- | --- |
| Android | 可读文档输入最大 64 MiB；压缩档案最多 20,000 条、扫描 256 MiB，选中的语义内容最大 48 MiB；输出最多 4 Mi UTF-16 单元。 |
| Web | 单文件最大 150 MiB；ZIP 进入 Mammoth/SheetJS 等解析器前也会预检，最多 12,000 条、总展开 220 MiB、单项 32 MiB；输出最多 4 Mi UTF-16 单元；内联图片单张 2 MiB、合计 10 MiB。 |
| iOS | 可重排文档输入最大 64 MiB，Kindle 解压正文最大 16 MiB，ZIP 最多 4,096 条，输出最多 4 Mi UTF-16 单元；PDF、CBZ 和图片另受 512 MiB 顶层文件上限保护。 |

超大电子表格按平台资源模型降级：Web 每表最多读取前 3,000 行 / 200 列、所有工作表合计保留前 60,000 个单元格并追加截断提示；Android 与 iOS 使用各自的结构上限，超限会明确失败。三端都不会静默执行宏、公式或嵌入对象。

三端统一规定：超过 65,536 个 UTF-16 单元的正文仍可正常投送，但不复制进十条本机历史，避免浏览器存储、SharedPreferences 或 UserDefaults 被大文档撑满。

### 三端同步开发约定

从本次文档导入扩展起，凡影响投送输入、格式识别、安全清洗或解析上限的功能，必须在同一次发布中同时评估 Android、Web、iOS；能力可行时同步实现和测试。如因平台 API 或可用解码器无法对齐，必须在上表和发布说明中记录例外、降级交互与测试证据，不以静默不支持代替对齐。

第三方解析依赖许可证见 [Web 发送端声明](app/src/main/assets/web/lib/THIRD_PARTY_LICENSES.txt)、[Android 发送端声明](sender/THIRD_PARTY_NOTICES.md) 和 [iOS ZIPFoundation 许可证](ios/Vendor/ZIPFoundation/LICENSE)。

**窗口实时投送（M4，getDisplayMedia + A2 快刷）**：发送页"选择窗口实时投送（横屏）"→ 浏览器原生窗口选择器 → 约 2 帧/秒定时抓帧 → 缩略图变化检测（画面静止不发，省刷新省电）→ 横屏窗口旋转 90° 铺满竖屏 → 抖动位图通道 → 设备端 A2 快刷模式直播上屏（每 24 帧插一次 FULL_GC16 全刷清残影），上屏回执门控防帧积压（超时丢帧）。可暂停定格 / 继续，结束后设备恢复原刷新模式。
**注意**：该 API 要求安全上下文，`http://192.168.x.x:8383` 需在电脑浏览器做一次性设置：`chrome://flags/#unsafely-treat-insecure-origin-as-secure` → 填入设备发送页地址 → Enabled → 重启浏览器。

**墨水屏刷新模式控制（M4 关键突破）**：rk3576_ebook 内置 Rockchip `android.os.EinkManager` 与 `eink` 系统服务（与微信读书/起点墨水屏版同源）。隐藏 API 策略会过滤反射（构造器/字段/asInterface 均不可见），最终方案：编译期 stub 直连拿 `ServiceManager.getService("eink")` 的 binder，再 `IBinder.transact` 手写 Parcel 调 `setProperty("sys.ebook.mode", v)`（事务码 5，root 下 `service call` 穷举定位）。模式常量：EPD_AUTO="0"、EPD_FULL_GC16="2"、EPD_A2="12"（快刷）、EPD_DU="14"。模式在息屏后会被系统重置，故进入直播重设、退出恢复。调试端点 `GET /debug/eink?mode=N&flash=N`。编译期 stub 位于 `app/src/main/java/android/os/`（EinkManager / IEinkManager / ServiceManager，仅供编译，运行时由 bootclasspath 真身接管）。

**点选投送（适配手机端）**：直接点击发送页的拖放大框即可打开系统文件选择器——手机浏览器自动调起相册 / 文件管理器；选中后走与拖拽相同的分发（图片→位图、PDF→位图分页、上表可读文档→语义排版）。发送页已做窄屏移动端布局适配。

**阅读格式面板（M4）**：文字模式中央点按唤起原生面板——字号（70%–160%，5% 步进）、行距（1.4–2.4）、边距（50%–150%）、字体（黑体/楷体），调参即重排且按 page/pages 比例保持阅读位置；SharedPreferences 持久化，对新内容同样生效。

**双指手势（M4）**：文字模式双指开合 = 字号升/降一档（矢量重排，任意字号都锐利）；位图（图片/PDF/直播画面）双指缩放（1–4 倍，焦点缩放）+ 放大后单指拖动平移，手势期间自动切 A2 快刷跟手、抬手恢复原刷新模式；缩放状态下点按翻页自动禁用，缩回 1 倍恢复。

**位图阅读设置面板（v1.3）**：图片/漫画/PDF 阅读界面点按屏幕中央唤起——翻页方向切换（左旧右新 ↔ 日漫点左翻下一页）、对比度 ±5 档（ColorMatrix 实时生效，不伤原图）、全刷一次清残影（漫画连翻后必备）、保存到首页列表、关闭。

**已保存内容（M4）**：投送内容默认即投即弃、零缓存残留；有价值内容可手动保存——文字模式格式面板 / 位图模式中央点按操作条中点「保存」，落盘到应用私有目录（`files/saved/`，文字存 HTML、位图按页存 PNG + meta.json）。待机页（首页）显示保存列表（类型/标题/页数/大小/时间），点按离线打开（位图缺页直接从磁盘读，无需电脑在线），长按弹确认框删除。

**留待后续（M4 余项）**：内容到达时唤醒熄屏设备（WakeLock）、直播帧率/画质调优（DU 模式、ROI 局部刷新）、mDNS / 配对 PIN / 多设备、PDF 整本保存（当前按已缓存页保存）。

## 安卓发送端（sender/ 模块，com.motou.sender）

与网页端同协议 v2 的原生安卓发送端，功能对齐网页端，另有定制能力：

- **全部网页端功能**：文字/网址投送（网址经设备 `/fetch` 代理抓取 + 本地正文提取）、图片灰度抖动（Floyd–Steinberg Kotlin 移植）→ 位图通道、PDF（系统 `PdfRenderer` 分页渲染 + 设备缺页回请 + 预取窗口 + 本地翻页遥控）、Markdown / EPUB / MOBI / AZW / AZW3 / DOC / DOCX / PPT / PPTX / XLS / XLSX → 语义排版通道、历史记录（本机最近 10 条点按重投）
- **剪切板监控（定制）**：回到前台时检查剪切板，发现新内容（≥6 字符）弹窗询问投送，网址自动走抓取通道；已询问过的内容去重不重复弹
- **分享接收（定制）**：注册 ACTION_SEND / ACTION_VIEW，接收文字、图片、PDF、电子书、Markdown 和新旧 Office 文件，也可打开 http(s) 链接；在系统分享面板和“打开方式”中选择墨投即可投送
- 连接：**NSD 自动发现**（设备端广播 `_motou._tcp.`，发送端首页列出在线设备点按即连）、手填设备 IP（记住上次）、**扫码连接**（CameraX 预览 + ZXing 解码墨水屏待机页二维码），hello 握手后自动适配设备分辨率与灰阶数；**多设备管理**：连接成功自动记忆（最多 10 台，按 IP 去重），已存设备点按切换、长按删除
- **批量图片 / 漫画模式（v1.5）**：文件选择器多选图片 → 按文件名自然排序（"2.jpg" < "10.jpg"）打包成一个多页位图文档（与 PDF 同通道：设备缺页回请 + 预取下一张 + 翻页遥控），大图按设备分辨率采样解码防 OOM
- **漫画压缩包（v1.6）**：直接打开 CBZ/ZIP（JDK 内置）与 CBR/RAR（junrar），懒解析——翻到哪页读哪页，不整包解压；图片页自然排序后走漫画通道
- **跳页（v1.7）**：遥控条页码可点按，输入 1–N 直接跳转（漫画 / PDF 通用）
- **书架（v1.8）**：漫画/PDF 打开即自动入架（SAF 持久授权，重启可续访），翻页自动记进度，书架条目显示"已读 x/N 页"，点按断点续投（直接跳到上次页码），长按下架；文件失效自动下架
- 文档解析额外使用 jsoup 与 commonmark-java，网络层使用 OkHttp；minSdk 26，无需存储权限（SAF 选文件）
- 待二期：~~NSD 自动发现设备~~（v1.5 已上线）

### 录屏实时投送（MediaProjection，v1.2 已上线）

- 一键把手机屏幕实时投到墨水屏：`CastLiveService` 前台服务（mediaProjection 类型）→ VirtualDisplay → ImageReader 抓帧（约 2 帧/秒，16×16 灰度采样变化检测，画面静止不发省刷新）→ 有序抖动 → `live:true` 位图通道，设备端 A2 快刷直播上屏（无 eink 服务的设备自动降级）
- 抓帧宽度压到设备屏宽减少无谓缩放；手机横屏时画面旋转 90° 铺满竖屏设备（与网页端同策略）
- 停止即发 `live.end`，设备恢复原刷新模式
- **流畅度优化（v1.4）**：直播帧 PNG→JPEG（体积 1/5–1/10）+ 4×4 Bayer 有序抖动替代 FS（CPU 省一个量级，静止内容仍走 FS PNG）+ 丢帧背压（发送队列 >256KB 直接跳过当帧，宁可降帧率不让延迟滚雪球——此前"时而流畅时而卡死"的主因）

产物：`sender/build/outputs/apk/debug/sender-debug.apk`（工作区根目录另有 `墨投-发送端-v1.3.apk` 副本，含扫码连接 + 录屏投送 + 反向控制）

### 反向控制（V1：点按 + 滑动，v1.3 / 设备端 v1.1 已上线）

墨水屏上的触摸实时回注到手机，实现"看着墨水屏操作手机"：

- **链路**：墨水屏直播画面点按/滑动 → 设备端把 View 坐标逆变换（含用户缩放）为画面归一化坐标 → WS 回传 `{type:"touch", kind:"tap"|"swipe", x,y,x2,y2}` → 手机端 `CastLiveService` 逆映射（去 fit 居中留白 → 去 90° 旋转 → 去抓帧缩放）为真实屏幕坐标 → 无障碍服务 `TouchService`（`dispatchGesture`）注入点按（80ms）/滑动（300ms）到前台应用
- **开启方式**：发送端首页"反向控制"按钮跳系统无障碍设置，找到「墨投·发送端」开启一次即可（也可用 adb `settings put secure enabled_accessibility_services` 代开）；按钮实时显示开启状态
- **V1 限制**：反馈环约 0.7–1.5 秒（抓帧 2fps + 传输 + 刷新），适合点按/翻页/滚动，不适合快速连续操作；手机横屏投送时的旋转坐标映射按 `postRotate(90)` 推导，未经充分实机验证；捏合缩放（双指）留 V2；落在画面留白区的触摸被忽略
- 设备端改动：`Protocol.touchTap/touchSwipe` + `MainActivity.emitLiveTouch`（仅直播模式生效，与翻页手势互不干扰）

## 构建

需要 JDK 17+ 与 Android SDK（34）。推荐直接用 Android Studio：

1. Android Studio（Hedgehog 或更新）→ Open → 选择本目录，等待 Gradle Sync 完成。
2. 真机开启 USB 调试连接，点击 Run；或 `Build > Build APK(s)`。

命令行（需已安装 Android SDK 并配置 `ANDROID_HOME` 或 `local.properties` 中的 `sdk.dir`）：

```bash
./gradlew assembleDebug   # Windows: gradlew.bat assembleDebug
# 产物：app/build/outputs/apk/debug/app-debug.apk
```

本仓库已验证的无 IDE 构建环境（Windows）：JDK 21（Eclipse Adoptium）+ 工作区内 `android-sdk/`（经 `C:\motou-sdk` 目录联接规避中文路径）+ Gradle 走腾讯镜像（见 `gradle/wrapper/gradle-wrapper.properties` 注释）。

## 使用

1. 设备与电脑连同一 WiFi。
2. 设备打开墨投，待机页显示二维码与 `http://<设备IP>:8383`。
3. 电脑浏览器打开该地址（或扫码），顶栏显示"已连接"。
4. 拖入文字 / 图片 / PDF / 上表可读文档（或 Ctrl+V 粘贴文字、截图）→ 设备端即时显示。
5. 设备端点按屏幕左右区域整屏翻页；电脑端"上一页/下一页"遥控；两端页码同步。
6. 设备端按返回键回到接收页。

## 测试与验证（verify/）

- `logic-test.js` — 发送页/阅读器内嵌脚本逻辑测试（桩 DOM/WS，28 项，含接收端 HTML 最终清洗/CSP 与大文档历史边界）
- `document-import-test.js` — Web 文档导入安全与资源边界测试（15 项，含 ZIP 预检、表格预算、MIME、DRM、PPT 递归与输出上限）
- `dither-test.js` — Floyd–Steinberg 抖动算法验证（量化级别、均值保持、纯色不变性，6 项）
- `e2e-ws.js` — M1 排版通道真机端到端（hello → 投送 → state → nav 同步）
- `e2e-bitmap.js` — M2 位图通道真机端到端（content.begin → 二进制页 → rendered → 缺页回请 → clear）
- `e2e-sender-chrome.js` — 发送页真实浏览器端到端（headless Chrome CDP 模拟拖入图片/PDF → 设备上屏回执）
- `e2e-m3-chrome.js` — M3 端到端（PC 本地文章页经设备 /fetch + Readability 上屏、docx 经 mammoth 上屏、历史记录与重投）
- `e2e-pick-chrome.js` — 点选文件端到端（CDP 模拟系统选择器返回 → 图片→位图、txt→排版）
- `e2e-live-chrome.js` — M4 窗口实时投送端到端（假捕获源动态画面 → 帧流上屏回执、暂停/继续、结束后恢复刷新模式）
- `tap-nav-test.js` — 位图点按翻页 + 连续换文档压力测试（recycled bitmap 竞态回归）
- `save-test.js` — 已保存内容真机端到端（文字/位图保存落盘 → 首页列表 → 离线打开 → 长按删除，分阶段配合 adb 点按与截图）
- `sender-e2e.js` — 安卓发送端真机联调（PC 侧 WS 观察墨水屏回执 + adb 驱动手机：文字投送、分享 Intent 投递、历史重投、网址抓取）

## 代码结构

```
app/src/main/
├── java/com/motou/app/
│   ├── MainActivity.kt        # 单 Activity 三模式：待机页 / WebView 排版阅读 / 位图直显
│   ├── server/
│   │   ├── MoTouServer.kt     # Ktor：assets 静态资源 + WS /channel（JSON 控制帧 + 二进制内容帧）
│   │   ├── ServerService.kt   # 前台服务，持有服务器
│   │   ├── Protocol.kt        # 协议 v2：hello/state/html/nav + content.begin/page/rendered/clear
│   │   └── ContentBus.kt      # 服务器↔界面 的 Flow 消息总线
│   └── util/Net.kt  QrCode.kt  SavedStore.kt  Eink.kt
├── assets/
│   ├── renderer/reader.html   # 设备端排版模板：CSS 多列分页、整屏无动画翻页、黑体 Medium
│   └── web/                   # 电脑端发送页（原生 HTML/CSS/JS，零构建）
│       ├── app.js             # 排版通道 + 位图通道（图片/PDF）+ 预取窗口
│       ├── dither-worker.js   # Floyd–Steinberg 灰度抖动 Worker
│       ├── document-import.js # Markdown / 电子书 / 新旧 Office 语义导入与安全清洗
│       └── lib/               # PDF.js、Mammoth、Marked、SheetJS、MOBI/ZIP 等离线依赖
└── res/                       # 墨水屏规范资源：白底黑字、零动画主题
```
