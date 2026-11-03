# Noctalia Mic Denoise

[Noctalia](https://noctalia.dev) v5 插件：[`mic-denoise`](mic-denoise/README.md) —— RNNoise 实时麦克风降噪，
在控制中心/栏一键开关，关闭时 **零 DSP 开销**。

本仓库按官方 `/noctalia-dev/official-plugins` 与 `/noctalia-dev/community-plugins`
的目录规范组织，可直接作为 `path` / `git` 源使用，也可提交到社区插件商店。

```
catalog.toml          # 源索引：每个插件一行 [[plugin]]
.luaurc               # Luau languageMode = nonstrict
.vscode/settings.json
install.sh            # 注册本仓库为 path 源并启用插件（无需 root）
uninstall.sh          # 卸载（--purge 同时删除生成的 PipeWire 配置）
tests/smoke.sh        # 清单/入口/翻译/后端自检（CI 也跑这个）
.github/workflows/    # checks
mic-denoise/          # 目录名 = 插件 id 中 "/" 之后的部分
```

## 安装

```sh
git clone https://github.com/Goldppx/noctalia-mic-denoise.git
cd noctalia-mic-denoise
./install.sh            # 依赖检查 + 注册源 + 启用插件
./install.sh --restart  # 若虚拟源尚未加载，顺便重启 PipeWire
sh tests/smoke.sh       # 自检
```

依赖（Arch / CachyOS）：

```sh
sudo pacman -S pipewire noise-suppression-for-voice libpulse
```

完整依赖树见 [mic-denoise/README.md](mic-denoise/README.md#最小依赖树)。

## 验证与合规

```sh
noctalia plugins lint mic-denoise   # 0 errors / 0 warnings
sh tests/smoke.sh                   # all checks passed
```

| 规范项 | 状态 |
|---|---|
| 清单必填字段（id/name/version/plugin_api/author/license） | ✅ `plugin_api = 17` |
| 目录名 = id 后缀（`mic-denoise/`） | ✅ |
| 入口：`[[service]]` `[[shortcut]]` `[[widget]]`，id 唯一 | ✅ |
| 插件级 `[[setting]]`（`label_key` / `description_key` / `min`） | ✅ 3 项 |
| `translations/en.json` 为源字符串 | ✅ 另有 `zh-Hans.json` |
| `README.md` + `thumbnail.webp` + `LICENSE` | ✅ |
| `catalog.toml` 索引 | ✅ |
| service 独占逻辑、UI 入口走 `noctalia.state` 命令通道 | ✅ 与官方 `screen_recorder` 同构 |

## 开发

```sh
noctalia plugins lint mic-denoise
sh tests/smoke.sh
noctalia msg config-reload                      # 改了 plugin.toml 后
noctalia msg plugin goldesquemoon/mic-denoise:state all toggle   # 直接驱动 service
```

编辑器补全（官方 API 类型定义不进仓库）：

```sh
curl -fsSL -o noctalia.d.luau \
  https://raw.githubusercontent.com/noctalia-dev/official-plugins/main/noctalia.d.luau
```

## 许可

MIT，见 [LICENSE](LICENSE)。
