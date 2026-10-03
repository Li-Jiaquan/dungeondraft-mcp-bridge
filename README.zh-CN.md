# Dungeondraft MCP

[English](README.md) · 简体中文

这个项目让 MCP 客户端操作正在运行的 Dungeondraft：查询地图和素材、绘制地形与建筑、设置灯光、导入本地 PNG、管理楼层，并保存或导出地图。

项目包含两部分：`mod/` 中的 Dungeondraft 扩展在软件内监听本机 `127.0.0.1:8787`；`server/` 中的 Python MCP 服务通过标准输入输出向客户端提供工具，再把绘图指令发给扩展。两者只在本机通信。

本项目基于 [Brandon Florian 的 dungeondraft-mcp](https://github.com/brann-dev/dungeondraft-mcp) 扩展。原作者的 MIT 许可及版权声明保留在 [LICENSE](LICENSE) 中。

## 功能

- 查询地图、楼层、物件和已加载素材；用画面捕获或全图导出检查绘制效果。
- 绘制物件、墙、路径、门窗、屋顶、图案地板、洞穴、水域和材质。
- 使用四种或八种地形槽，填充区域、柔化笔刷以及沿路径绘制道路；八槽混合统一归一化。
- 新建、复制、切换、排序和对照楼层，设置绘图层，并以悬崖、贴图和光照表达高低地。Dungeondraft 在这里没有可调用的三维高度场。
- 设置环境光与独立光源的颜色、亮度、范围和阴影。使用原生灯光纹理和墙体遮挡。
- 导入本地 PNG 作为可编辑位置、大小和图层的图片物件；图片数据会嵌入地图文件。整张图片不会自动变成独立地形和墙体。
- 将地图保存为原生 `.dungeondraft_map`，导出 PNG、JPEG、WEBP 或 Universal VTT。
- 通过 `native_targets`、`native_describe`、`native_get`、`native_set`、`native_call` 探查当前安装版本开放的原生接口；通过 `ui_tree`、`ui_action` 访问原生控件。

通用原生接口有版本和数据类型边界；发现可用方法不代表每个原生按钮和参数都经过验证。原生调用和部分批量操作没有统一自动撤销，建议先保存地图副本。

## 安装

需要 Dungeondraft 1.2.0.1（当前实测版本）、Python 3.10 或更新版本，以及一个支持本地标准输入输出服务的 MCP 客户端。

1. 把 `mod/dungeondraft-mcp-bridge/` 复制到 Dungeondraft 的 Mods 目录，在软件中启用 **MCP Bridge**，然后打开一张地图。
2. 在项目根目录创建虚拟环境并安装服务：

   ```powershell
   py -3 -m venv .venv
   .\.venv\Scripts\python.exe -m pip install -e .\server
   ```

3. 在 MCP 客户端中注册 `\.venv\Scripts\dungeondraft-mcp.exe` 的**绝对路径**。例如配置文件中的命令字段应是该可执行文件的完整路径。
4. 重启 MCP 客户端并在 Dungeondraft 中重新加载扩展。先调用 `ping`、`get_status`、`list_asset_categories` 检查连接和素材。

Linux/macOS 用户可将第二步命令替换为 `python3 -m venv .venv` 与 `.venv/bin/pip install -e ./server`，注册 `.venv/bin/dungeondraft-mcp`。

坐标单位是软件的世界像素，默认每格 256 像素。绘制前先用 `list_assets` 查出当前已加载素材的路径。图片导入需本地 PNG 的绝对路径；保存和导出也需绝对路径。保存到已有文件时会生成 `.mcp-backup` 备份。

## 测试与限制

离线回归：`\.venv\Scripts\python.exe -m unittest discover -s tests -v`。在 Dungeondraft 1.2.0.1 上已发现并逐项成功调用全部 71 个 MCP 工具；三层测试地图完成了绘制、保存、重开以及 PNG、JPEG、WEBP、Universal VTT 导出。测试地图用到用户自己的素材包，未随公开仓库分发。

地形高低通过楼层、叠放层、悬崖和灯光表现；当前接口不提供可编辑的三维地形高度场。灯光使用 Dungeondraft 的二维光照系统，支持遮挡与距离衰减，不能据此宣称真实三维光线追踪或严格的反平方定律。

当前软件版本的原生 Universal VTT 导出有时只留下临时 PNG。MCP 会结合软件导出的图片与原生地图数据生成可用的 `.dd2vtt`，保留墙体视线阻挡、门窗、环境光和独立灯光。这个替代导出尚未把洞穴边缘与物件剪影转成 VTT 视线阻挡线。

更多接口、通信协议和开发细节见 [英文 README](README.md) 与 [PROTOCOL.md](PROTOCOL.md)。
