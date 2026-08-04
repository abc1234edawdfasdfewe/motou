# 墨投 iOS 发送端

原生 SwiftUI iPhone/iPad 客户端，对接现有墨水屏设备端的协议 v2：

- WebSocket：`ws://<设备>:8383/channel`
- 网页抓取代理：`http://<设备>:8383/fetch`
- Bonjour：`_motou._tcp`

## 安卓功能对应关系

| 能力 | iOS 实现 |
| --- | --- |
| 手填 IP、扫码、NSD、已存设备 | 手填主机、二维码、Bonjour、最近设备 |
| 文字、网址、图片、PDF、docx、txt/md | 原生投送管线；网址优先走设备 `/fetch`，失败回退手机直连 |
| 多图漫画、CBZ/ZIP、跳页 | PhotosPicker / 本地 ZIPFoundation / 页码遥控；PDF 与 CBZ 均按文件、按页读取 |
| 历史、书架、断点续投 | UserDefaults + security-scoped bookmark |
| OCR | PaddleOCR-VL 异步任务，Token 存 Keychain |
| AI 对话、语音输入、朗读、设备追问 | OpenAI 兼容接口 + Speech + AVSpeechSynthesizer；前台闭环 |
| 系统分享 | Share Extension + App Group 收件箱 |
| Android 前台剪贴板提示 | iOS 剪贴板隐私规则下改为用户主动点“粘贴” |
| CBR/RAR | 首版不支持；iOS 无系统 RAR 解码器，当前支持 CBZ/ZIP |
| Android MediaProjection 全系统直播 | 当前 Apple SDK 已弃用对应 ReplayKit 广播扩展 API，未作为首版能力（见 [ReplayKit](https://developer.apple.com/documentation/replaykit)） |
| Android 无障碍反向控制 | iOS 无公开的跨 App 触控注入 API，不支持 |
| 锁屏后常驻 WS 续聊 | iOS 不允许普通 App 长期保持局域网 WebSocket，仅前台可靠可用 |

## 构建

本机全局 `xcode-select` 可能仍指向 Command Line Tools，可直接用：

```bash
cd ios
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MoTouSender.xcodeproj \
  -scheme MoTouSender \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

工程要求 XcodeGen 2.46+、Xcode 15+、iOS 17+。ZIPFoundation 0.9.20 已放在 `Vendor/ZIPFoundation`，由 Swift Package Manager 以本地包方式解析，离线可构建；许可证见该目录 `LICENSE`。

已启动一个模拟器时，可运行完整单元测试：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MoTouSender.xcodeproj \
  -scheme MoTouSender \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

真机签名前需要：

1. 在主 App 与 Share Extension 选择同一开发团队。
2. 为两个 Target 启用 App Group，并把 `group.com.motou.sender` 换成开发者账号可用的组标识。
3. 保持两份 entitlements 与 `SharedInbox.appGroupID` 一致。
4. 首次启动允许“本地网络”；扫码/拍照/语音按功能授权。
5. 发布前根据实际 AI/OCR 服务的数据处理政策填写 App Store 隐私问卷；工程已为主 App 和分享扩展声明 UserDefaults required-reason API。

## 验证原则

- 只有收到设备 `hello` 后才进入 ready，避免使用默认分辨率误投。
- 位图页必须由同一串行队列依次发送 `page` JSON 与紧随的 binary，期间不能插入另一页 metadata。
- PDF/漫画使用文件后端并只预取当前页附近窗口，不整本驻留内存或推入 WebSocket 队列。
- 书架只保存安全作用域书签，不保存失效的临时 URL。
- LLM API Key 与 OCR Token 不写入普通偏好或日志。
