# 开发这个组件（或任意 SnowDesktop Lua 组件）

这份文档是本组件开发过程中沉淀下来的、与具体数据源无关的经验。目标是让下一个人（或下一次的 AI 会话）不必重新摸一遍宿主。

## 工具

SnowDesktop 自带组件工具链，位于安装目录下：

```
<SnowDesktop 安装目录>\widgets\snowdesktop-lua-widget\
├── bin\snowwidget.exe        # lint / test / preview / quality / pack / validate / permissions
│                             # api-contract / view-contract / capabilities 可查宿主契约
├── scripts\init_widget.ps1   # 新建组件包（生成 UUID 与本地化前缀）
├── references\               # API 手册、布局系统、布局模式、视觉规范
└── library\snowdesktop-v2.lua # 函数的 Luau 类型定义
```

> 注：`snowwidget system-contract` 在 1.0.15 上会崩溃，其它子命令正常。

新建组件**不要手抄模板**，用：

```powershell
& scripts\init_widget.ps1 -Destination <目录> -Slug <kebab-case> `
  -Name <名称> -Description <描述> -Author <作者>
```

生成的包 `id`（UUID）是实例身份，永远不要改。

## 迭代闭环

按代价从低到高，每一步都要过：

```powershell
snowwidget lint    <包目录>
snowwidget test    <包目录>                    # tests/*.lua，纯 Lua 用例
snowwidget preview <包目录> out.png --columns 4 --rows 2 --locale zh-CN
snowwidget quality <包目录>                    # 校验 + lint，缺预览图会失败
snowwidget pack    <包目录> name.snowwidget
```

`preview` 的常用参数：

| 参数 | 用途 |
| --- | --- |
| `--columns/--rows` | 跨度，至少覆盖默认值、最小值、一个更大的值 |
| `--appearance` | `dark/light/glass-dark/glass-light/glass-transparent/acrylic-dark/acrylic-light` |
| `--background <png>` | 合成用背景；只参与合成，不会进包 |
| `--canvas-size 512 --padding 48` | 生成 512×512 的创意工坊/目录图 |
| `--storage key=value` | 覆盖 `previewData.storage`，用来喂测试数据 |
| `--dpi` | 96–480，检查缩放 |

两个坑：

- `preview` 会先校验包，**清单里的 `preview` 文件必须已经存在**。迭代期可先删掉该字段。
- 预览通过只代表"渲染完成"，不代表"能看"。

## 验证与调试手法

- **逐像素回归**：任何重构前后用同一参数渲染，再 `PIL.ImageChops.difference(a, b).getbbox() is None`。本项目靠它把 800 多行的 `render()` 拆成函数而零视觉变化。
- **探针包**：宿主行为不确定时，建一个临时包，`main.lua` 里把 `widget.hasFeature(...)`、`widget.theme()` 的字段、或某次 `draw.*` 的结果画出来看，比翻文档快。
- **桌面实拍**：PowerShell `CopyFromScreen` 抓屏做最终验收。注意**热重载有延迟**，刚改完截到的可能还是上一帧。
- **真实数据**：测试与 fixture 用真实抓包，再用 `tests/` 固定下来；发布前脱敏。

## 布局与视觉

先读 `references/layout-system.md` 与 `references/layout-patterns.md`。本组件采用的几条通用做法：

- 字号用 `ui.metrics().layoutRowHeight` 封顶（约 0.3–0.45 × rowUnit），几何随内容框比例：跨度变大应当"显示更多行"，而不是"字更大"。
- 卡片按内容定高，每一列各自垂直居中；否则单个元素会被拉成空面板。
- 所有标签都走"候选链降级"（例：模型 → provider → 网关 → 不显示），**永远不出现半截字**。
- 行内两段文字：左段 `maxWidth = 剩余宽`，右段右对齐单独绘制，别拼成一整串（截断会剪掉尾部）。
- 居中文本先按可用宽 clamp 再算 x，否则超宽文本会从父容器左边溢出。
- `measureText` 按 (文本, 字号, 粗体) 记忆化，一帧能省掉大半宿主调用。
- 结构上把"算几何/字体/文案"和"画各个区域"分开：`buildFrame()` → `drawTopBar/drawFooter/drawWires/drawHub/drawCards` → `render()` 只做编排。

配色要读 `widget.theme().contentTheme`（0 = 浅色前景，1 = 深色前景），不要用 `context.theme.mode`：深色玻璃材质可能报 `mode=light` 而前景是浅色，直接导致白字白底。

## 数据层

把解析、投影、格式化放进 `modules/`，保持纯函数、不碰宿主 API，`snowwidget test` 就能覆盖。宿主能力用 `widget.hasFeature()` 探测；权限必须写进清单，否则 lint 与运行都会拦。

## 发布

- `.snowwidget` 不进仓库（`.gitignore`），挂到 GitHub Release；README 里写清"设置 → 组件 → 从文件安装…"。
- 版本从 **1.0.0** 起步：开发期的迭代号不要带进公开发布。
- 脱敏：测试里的真实账号名/邮箱/手机号、`previewData.storage`（会被渲染进目录图）、注释里的 id 片段、以及 git 历史都要清。force-push 之后记得删掉旧 tag 与旧 Release。
- 用了第三方资产（图标等）要在 README 与代码头注明来源与许可，并声明非官方。
