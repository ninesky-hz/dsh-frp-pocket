# 图标方向（dsh-frp-pocket / DSH 口袋隧道）

## 五条方向

- **产品**：把跑在家里那台机器上的 DSH 装进兜里 —— 手机连上 frp 隧道，跟远端 agent 对话、下指令、看它执行。
- **性格**：冷静、精确、带一点暖。「顺手」「不吵」「像工具不像玩具」。
- **世界**：深夜的终端和一根接通的线。石墨机箱、薄荷色光标、没有一处发光。
- **留白与高光**：图标本身不铺色 —— 唯一的高光就是那枚薄荷色光标，其余全是石墨。
- **签名**：`›` 提示符 + 一枚方块光标。全 app 只有这一处出现，意思是「这条会话正等着你敲字」。

## 审计：旧图标

| 位置 | 问题 |
| --- | --- |
| `mipmap-*/ic_launcher.png` | Flutter 默认图标（蓝色 M 形箭头双箭头）。与产品零关联，且是「没换过」的默认值。 |
| 缺 `mipmap-anydpi-v26/ic_launcher.xml` | 没有自适应图标。Android 8+ 会把方图硬套圆/方遮罩，四角出现白边或裁切。 |
| `drawable/launch_background.xml` | 纯白底 + 空内容。深色主题下启动一瞬白闪，跟 `#111110` 的界面撞得很明显。 |
| `values/styles.xml` `NormalTheme` | `?android:colorBackground` 在深色下仍是白，Flutter 首帧前露白。 |

## 落地的九道工序（对图标这一版而言）

1. **间距**：图形收在中心 60% 安全区（自适应图标 108dp 画布 / 72dp 安全区），四角留够遮罩余量；笔画 114/1024，光标 204×200，间距 44 —— 全是 4 的倍数。
2. **颜色**：只有两个色值，都取自 `main.dart` 的 ColorScheme —— 底 `#111110`（surface），笔画 `#7FD3C0`（深色 primary）。浅色启动屏用 `#1F6F63`（浅色 primary）配 `#FAFAF9`。无渐变、无发光、无阴影。
3. **图标（图形语言）**：圆头圆拐的单笔画折角，和 `AppIcons` 里 Cupertino 那套细笔画的调子对齐；只用两个元素，第三笔就糊了。
4. **文案**：不改应用名（`DSH 口袋隧道`）。
5. **字体**：图标内无文字 —— 48px 下的任何字都会变成噪点。
6. **布局**：光学居中在 (512, 512)，折角与光标各占一半视觉重量。
7. **细节**：光标圆角 24（外框无，所以不必套嵌套圆角公式）；传统 mipmap 自带 22.5% 圆角，自适应图标交给系统遮罩。
8. **视觉**：没有生成图。图形本身就是产品的那一个真实对象（终端提示符），比任何渲染图都准。
9. **动效**：没有。启动屏是静止的一帧。

## 复现

```powershell
$py = "C:\Users\Chen\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
& $py packages/app/tool/icon/generate_icon.py preview          # 出 7 版对比图
& $py packages/app/tool/icon/generate_icon.py install A3-prompt-heavy
& $py packages/app/tool/icon/generate_icon.py splash A3-prompt-heavy
```

候选表（`generate_icon.py` 里的 `CANDS`）：

| 名字 | 想法 | 结论 |
| --- | --- | --- |
| `A-prompt-cursor` | `›` + 方块光标 | 好，但间距偏松、略偏左 |
| `A2-prompt-tight` | 收紧间距、光学居中 | 好 |
| **`A3-prompt-heavy`** | 笔画再厚一档 | **采用**：48px 下最硬 |
| `B-prompt-bar` | `›` + 下划宽条 | 两块分离，读起来像笑脸 |
| `C-window` | 终端窗口轮廓 + `›_` | 窗口和符号互相抢，小尺寸糊 |
| `D-tunnel` | 两端节点 + 连线 | 像钥匙 / 分享，不像隧道 |
| `E-bubble` | 气泡 + `›_` | 尾巴吃掉安全区，内部太挤 |

## 尺寸：预览必须按系统的裁切来画

自适应图标是 108dp 画布，但系统只露出**中间 72dp**。第一版把整块 108dp 当可见区
来预览，于是本地看着「刚好」，装到手机上大了约三分之一 —— 真机截图量下来，ink
占了可见区的 84%。

现在的算法不再手写缩放系数，而是先量 ink 宽度占画布的比例，再解方程：

```
scale = INK_FILL × SAFE_DP / (CANVAS_DP × ink_fraction)
```

`INK_FILL = 0.62` 是照一排真图标量的体量：四周都留气口，和相邻图标站在一起不挤。
`adaptive_icon()` 走的就是这条链（前景 → 裁中间 72/108 → 压石墨底 → 套 22.5% 圆角），
`mock` 用它画桌面，所以预览和真机终于是同一个东西。

教训一句话：**预览不复刻系统的裁切，就等于没预览。**
